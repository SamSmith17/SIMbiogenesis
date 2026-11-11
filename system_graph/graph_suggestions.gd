class_name GraphSuggestions
extends RefCounted

## The loop closer's ghosts (resource composition plan Phase 7): one
## LoopPlanner plan laid out beside the open port as cards that are NOT in
## the model. The canvas draws them faded with dashed wires (clicks go
## through them); the view's chip accepts, cycles or dismisses.
## Only on request: nothing here runs by itself.
##
## A suggestion: {key, sig, scope, open: {kind, side, kg_h, …}, plan, index,
## count, items, conns (a ChainWiring.plan), bbox: Rect2 (graph px), text,
## machines, gaps, tanks}. Steps no machine does (a class, a recipe) are gap
## nodes (`gap` true, DesignGap): drawn as gaps, placed as gap nodes.
##
## Dismissals are remembered per world (WorldPaths kind "suggestions"):
## {dismissed: {"<scope>|<kind>|<side>|<plan sig>": unix time}}.

const KIND := "suggestions"
const STEP := Vector2(230.0, 0.0)
const GAP_SIZE := Vector2(150.0, 110.0)
## How far below (a sink) or above (a source) the anchor the chain starts.
const OFFSET_Y := 90.0


## The item a plan joins: the machine the player asked from (`from_item`)
## when it has a port of the kind, else the scope's tank of the kind, else
## the first machine, plant or habitat with an output (sink) or input
## (source) of it.
## {id, kind, side, handle, tank: bool} ({} = none; a tank is wired by kind).
static func anchor_for(model, scope: String, kind: String, side: String, from_item: String = "") -> Dictionary:
	var k := ChainWiring.kind(kind)
	if not from_item.is_empty():
		var fi: Dictionary = model.get_item(from_item)
		var fty := str(fi.get("type", ""))
		if fty == "processor" or fty == "plant":
			for fp in ChainWiring.ports(fty, fi.get("specs", {}), side == "source"):
				if str(fp[0]) == k:
					return {"id": from_item, "kind": k, "side": side, "handle": str(fp[1]), "tank": false}
	var tanks := ChainWiring.scope_tanks(model, scope)
	if tanks.has(k):
		return {"id": str(tanks[k]), "kind": k, "side": side, "handle": "", "tank": true}
	for it in model.get_items_in_scope(scope):
		var d: Dictionary = it
		var ty := str(d.get("type", ""))
		if bool(d.get("is_ghost", false)) or (ty != "processor" and ty != "plant"):
			continue
		for p in ChainWiring.ports(ty, d.get("specs", {}), side == "source"):
			if str(p[0]) == k:
				return {"id": str(d.get("id", "")), "kind": k, "side": side, "handle": str(p[1]), "tank": false}
	return {}


## The ghost of `plan` (one of LoopPlanner.plan's) for the open loop `open`.
static func build(model, scope: String, open: Dictionary, plan: Dictionary,
		index: int = 0, count: int = 1, from_item: String = "") -> Dictionary:
	var kind := str(open.get("kind", ""))
	var side := str(open.get("side", "sink"))
	var anchor := anchor_for(model, scope, kind, side, from_item)
	var origin := Vector2.ZERO
	var push := Vector2(0.0, 60.0 if side == "sink" else -60.0)
	var a_item: Dictionary = model.get_item(str(anchor.get("id", ""))) if not anchor.is_empty() else {}
	if not a_item.is_empty():
		var ap := Vector2(float(a_item.get("x", 0.0)), float(a_item.get("y", 0.0)))
		var ah := float(a_item.get("height", 90.0))
		origin = ap + Vector2(0.0, ah + OFFSET_Y) if side == "sink" else ap - Vector2(0.0, OFFSET_Y + 130.0)
	else:
		var max_x := 0.0
		var min_y := 0.0
		var first := true
		for it in model.get_items_in_scope(scope):
			var d: Dictionary = it
			max_x = maxf(max_x, float(d.get("x", 0.0)) + float(d.get("width", 120.0)))
			min_y = float(d.get("y", 0.0)) if first else minf(min_y, float(d.get("y", 0.0)))
			first = false
		origin = Vector2(max_x + 120.0, min_y)
	var entries: Array = []
	var machines := 0
	var gaps := 0
	for st in plan.get("steps", []):
		var sd: Dictionary = st
		if str(sd.get("type", "")) == "preset":
			entries.append({"label": str(sd["label"]), "scale": float(sd.get("scale", 1.0))})
			machines += 1
		else:
			entries.append(_gap_entry(sd))
			gaps += 1
	var wire_anchor: Dictionary = {} if anchor.is_empty() or bool(anchor.get("tank", false)) else anchor
	var chain := ChainWiring.plan(model, scope, entries, {"origin": origin, "step": STEP, "push": push,
		"anchor": wire_anchor})
	var bbox := Rect2()
	var have := false
	for it2 in chain["items"]:
		var r := Rect2(float(it2["x"]), float(it2["y"]), float(it2["width"]), float(it2["height"]))
		bbox = r if not have else bbox.merge(r)
		have = true
	var tanks := 0
	for it3 in chain["items"]:
		if bool((it3 as Dictionary).get("store", false)) or bool((it3 as Dictionary).get("buffer", false)):
			tanks += 1
	var out := {"key": loop_key(scope, kind, side), "sig": plan_sig(plan), "scope": scope, "open": open,
		"plan": plan, "index": index, "count": count, "items": chain["items"], "conns": chain["conns"],
		"bbox": bbox, "anchor": anchor, "machines": machines, "gaps": gaps, "tanks": tanks,
		"unpowered": (chain.get("unpowered", []) as Array).size()}
	out["text"] = chip_text(open, plan, machines, gaps, tanks)
	if int(out["unpowered"]) > 0:
		out["text"] += " · no controller here to power it"
	return out


## A gap node for a step no machine in the library does (Phase 8): it
## takes what the step takes and delivers what it gives, as far as the
## elements allow, and its meter becomes the design brief. The process type
## rides along (`gap_class`) for the brief's energy numbers.
static func _gap_entry(st: Dictionary) -> Dictionary:
	var ins: Array = []
	if not str(st.get("takes", "")).is_empty():
		ins.append({"kind": str(st.get("takes", "")), "rate": 0.0})
	var outs: Array = []
	for g in st.get("gives", []):
		outs.append({"kind": str(g), "rate": 0.0})
	var label := str(st.get("label", "")).trim_prefix("recipe: ")
	var specs := DesignGap.make_specs("Gap: %s" % label, ins, outs, {"gap_class": str(st.get("class", ""))})
	return {"type": "processor", "label": "Gap: %s" % label, "gap": true, "width": GAP_SIZE.x,
		"height": GAP_SIZE.y, "specs": specs}


## A one-step plan that is a gap node for a loop nothing closes: a sink's
## gap takes the kind (what it gives is the player's to set), a source's
## gap delivers it.
static func gap_plan(open: Dictionary) -> Dictionary:
	var kind := str(open.get("kind", ""))
	var sink := str(open.get("side", "sink")) == "sink"
	var label := ("close the %s loop" % kind_word(kind)) if sink else ("make %s here" % kind_word(kind))
	return {"side": str(open.get("side", "sink")), "kind": kind, "kg_h": float(open.get("kg_h", 0.0)),
		"closes": 1.0, "complete": false, "adds": {}, "needs": [], "still_open": [],
		"steps": [{"id": "gap:" + kind, "type": "gap", "label": label, "class": "",
			"takes": kind if sink else "", "gives": [] if sink else [kind]}]}


## "Close the urine loop · 2 machines · +45 W · $900 · closes 100 %".
static func chip_text(open: Dictionary, plan: Dictionary, machines: int, gaps: int, tanks: int = 0) -> String:
	var kind := str(open.get("kind", ""))
	var nm := kind_word(kind)
	var parts := PackedStringArray()
	parts.append(("Close the %s loop" % nm) if str(open.get("side", "")) == "sink" else ("Make %s here" % nm))
	if machines > 0 or gaps == 0:
		parts.append(UiText.count(machines, "machine") + ((" and " + UiText.count(tanks, "tank")) if tanks > 0 else ""))
	elif tanks > 0:
		parts.append(UiText.count(tanks, "tank"))
	var adds: Dictionary = plan.get("adds", {})
	var w := float(adds.get("power_w", 0.0))
	if w >= 0.5:
		parts.append("+" + UiText.num(w, "W"))
	var cost := float(adds.get("cost", 0.0))
	if cost >= 1.0:
		parts.append("$" + UiText.thousands(int(round(cost))))
	parts.append("closes %s of it" % UiText.pct(float(plan.get("closes", 0.0))))
	if gaps > 0:
		parts.append("%s for what no machine does yet" % UiText.count(gaps, "gap node"))
	var needs: Array = plan.get("needs", [])
	if not needs.is_empty():
		var nk := PackedStringArray()
		for n in needs:
			nk.append(kind_word(str((n as Dictionary)["kind"])))
		parts.append("needs " + ", ".join(nk))
	return " · ".join(parts)


## A kind in a sentence: "urine", not "Urine (diverted)".
static func kind_word(kind: String) -> String:
	var nm := ResourceKinds.display_name(kind)
	var cut := nm.find(" (")
	if cut > 0:
		nm = nm.substr(0, cut)
	return nm.to_lower()


static func loop_key(scope: String, kind: String, side: String) -> String:
	return "%s|%s|%s" % [scope, kind, side]


static func plan_sig(plan: Dictionary) -> String:
	var ids := PackedStringArray()
	for st in plan.get("steps", []):
		ids.append(str((st as Dictionary).get("id", "")))
	return ",".join(ids)


static func dismiss_id(sugg: Dictionary) -> String:
	return "%s|%s" % [str(sugg.get("key", "")), str(sugg.get("sig", ""))]


static func is_dismissed(dismissed: Dictionary, scope: String, open: Dictionary, plan: Dictionary) -> bool:
	return dismissed.has("%s|%s" % [loop_key(scope, str(open.get("kind", "")), str(open.get("side", ""))),
		plan_sig(plan)])


# --- the world's dismissals ----------------------------------------------------

static func path_for_view(view: Node) -> String:
	if view == null or not view.has_method("_resolve_map_graph_key"):
		return ""
	var key := str(view.call("_resolve_map_graph_key"))
	if key.is_empty():
		return ""
	return WorldPaths.keyed_file(KIND, key.trim_prefix("map_"), "json")


static func load_dismissed(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and (d as Dictionary).get("dismissed", null) is Dictionary:
		return (d as Dictionary)["dismissed"]
	return {}


static func save_dismissed(path: String, dismissed: Dictionary) -> bool:
	if path.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "dismissed": dismissed}, "\t"))
	return true
