class_name ProcessPack
extends RefCounted

## A process as a thing you can keep, share and drop in again (pure). SCADA
## plan, Phase 9. A PACK = the parts of one process (graph items and the
## wires between them) with the control blocks, alarm rules and dashboard
## widgets that only read and drive those parts.
##
##   {v, name, note, items, conns, logic, alarms, widgets}
##
## `capture` cuts one out of a graph; `instantiate` gives every part a new id
## and rewrites every tag to match; `encode` / `decode` are the share code
## ("SMPR1:" + base64(gzip(JSON))) and the `.simproc` file. Everything that
## comes from outside goes through `clean`: sizes capped, known item types
## only, spec keys that name a path, a device or a token dropped (SimkitGuard),
## live state stripped. A pack never carries a real-output link.

const SimkitGuard := preload("res://core/simkit/simkit_guard.gd")
const VERSION := 1
const PREFIX := "SMPR1:"
const MAX_ITEMS := 60
const MAX_CONNS := 240
const MAX_LOGIC := 40
const MAX_ALARMS := 60
const MAX_WIDGETS := 60
const MAX_BYTES := 400000
const ITEM_TYPES := ["resource", "processor", "appliance", "acload", "acbreaker", "controller", "battery", "panel", "plant", "catchment", "wind", "hydro"]
## Tag heads that name a graph item in their second part.
const ITEM_TAGS := ["tank", "node", "valve"]
## Spec keys that are the running state, not the design.
const LIVE_KEYS := ["node_state", "node_state_reason", "node_state_kinds", "current_state", "ctl_block", "ctl_rate", "inflow_rate", "outflow_rate",
	"deficit_qty", "destroyed", "tripped", "trip_amps", "graph_automations", "bound_prop_id", "model_id", "scene_device_path"]


static func empty(pack_name: String = "Process") -> Dictionary:
	return {"v": VERSION, "name": pack_name, "note": "", "items": [], "conns": [], "logic": [], "alarms": [], "widgets": []}


## The item a tag names ("" = none: a site or logic tag).
static func tag_item(tag: String) -> String:
	var parts := tag.split(".")
	return str(parts[1]) if parts.size() >= 2 and str(parts[0]) in ITEM_TAGS else ""


## Every tag string in a value (a block, a rule, a widget).
static func _tags_in(v: Variant, out: Array) -> void:
	if v is Dictionary:
		for k in (v as Dictionary):
			_tags_in(v[k], out)
	elif v is Array:
		for x in (v as Array):
			_tags_in(x, out)
	elif v is String and not tag_item(v).is_empty():
		out.append(v)


## True when everything `v` names is in `ids` (and it names something).
static func _only_these(v: Variant, ids: Dictionary) -> bool:
	var tags: Array = []
	_tags_in(v, tags)
	if tags.is_empty():
		return false
	for t in tags:
		if not ids.has(tag_item(str(t))):
			return false
	return true


## Cut a pack out: `items` / `conns` are the scope's, `ids` the chosen item
## ids. Blocks, rules and widgets come along only when every item tag they
## carry is one of the chosen parts.
static func capture(pack_name: String, items: Array, conns: Array, ids: Array, logic: Array = [], alarms: Array = [], widgets: Array = []) -> Dictionary:
	var want := {}
	for id in ids:
		want[str(id)] = true
	var p := empty(pack_name)
	var cx := 0.0
	var cy := 0.0
	var n := 0
	for it in items:
		if it is Dictionary and want.has(str(it.get("id", ""))) and str(it.get("type", "")) in ITEM_TYPES:
			cx += float(it.get("x", 0.0))
			cy += float(it.get("y", 0.0))
			n += 1
	for it in items:
		if not (it is Dictionary) or not want.has(str(it.get("id", ""))) or not (str(it.get("type", "")) in ITEM_TYPES):
			continue
		var specs: Dictionary = ((it.get("specs", {}) as Dictionary) as Dictionary).duplicate(true)
		for k in LIVE_KEYS:
			specs.erase(k)
		(p["items"] as Array).append({"id": str(it["id"]), "type": str(it["type"]),
			"x": snappedf(float(it.get("x", 0.0)) - cx / maxf(float(n), 1.0), 1.0), "y": snappedf(float(it.get("y", 0.0)) - cy / maxf(float(n), 1.0), 1.0),
			"width": float(it.get("width", 0.0)), "height": float(it.get("height", 0.0)), "specs": specs})
	var kept := {}
	for it in p["items"]:
		kept[str(it["id"])] = true
	for c in conns:
		if c is Dictionary and kept.has(str(c.get("source_item_id", ""))) and kept.has(str(c.get("target_item_id", ""))):
			var cc := {}
			for k in ["polarity", "resource_type", "source_item_id", "source_handle_id", "target_item_id", "target_handle_id", "data_kind", "flow_width"]:
				if c.has(k):
					cc[k] = c[k]
			(p["conns"] as Array).append(cc)
	var block_ids := {}
	for b in logic:
		if b is Dictionary and _only_these(b, kept):
			(p["logic"] as Array).append((b as Dictionary).duplicate(true))
			block_ids[str(b.get("id", ""))] = true
	for r in alarms:
		if not (r is Dictionary):
			continue
		var tag := str(r.get("tag", ""))
		var its_block := tag.begins_with("logic.") and block_ids.has(str(tag.split(".")[1]) if tag.split(".").size() > 1 else "")
		if kept.has(tag_item(tag)) or its_block:
			(p["alarms"] as Array).append((r as Dictionary).duplicate(true))
	for w in widgets:
		if w is Dictionary and kept.has(tag_item(str(w.get("tag", "")))):
			var ww: Dictionary = MimicWidgets.normalized(w)
			ww["x"] = float(ww["x"])
			ww["screen"] = ""
			(p["widgets"] as Array).append(ww)
	return p


## A pack from anywhere, made safe. → {ok, pack, why}.
static func clean(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {"ok": false, "why": "That is not a process."}
	var d: Dictionary = raw
	if int(d.get("v", 0)) > VERSION:
		return {"ok": false, "why": "That process was made by a newer version of the game."}
	if not (d.get("items") is Array) or (d["items"] as Array).is_empty():
		return {"ok": false, "why": "That process has no parts."}
	if (d["items"] as Array).size() > MAX_ITEMS:
		return {"ok": false, "why": "That process has more than %d parts." % MAX_ITEMS}
	var p := empty(str(d.get("name", "Process")).strip_edges().substr(0, 60))
	if str(p["name"]).is_empty():
		p["name"] = "Process"
	p["note"] = str(d.get("note", "")).substr(0, 400)
	var seen := {}
	for it in d["items"]:
		if not (it is Dictionary):
			continue
		var id := str(it.get("id", ""))
		var type := str(it.get("type", ""))
		if id.is_empty() or id.length() > 80 or seen.has(id) or not (type in ITEM_TYPES):
			continue
		if not SimkitGuard._shape_ok(it.get("specs", {}), 0) or not (it.get("specs", {}) is Dictionary):
			continue
		var specs: Dictionary = SimkitGuard.clean_specs(it.get("specs", {}))
		for k in LIVE_KEYS:
			specs.erase(k)
		seen[id] = true
		(p["items"] as Array).append({"id": id, "type": type, "x": clampf(float(it.get("x", 0.0)), -20000.0, 20000.0),
			"y": clampf(float(it.get("y", 0.0)), -20000.0, 20000.0), "width": clampf(float(it.get("width", 0.0)), 0.0, 2000.0),
			"height": clampf(float(it.get("height", 0.0)), 0.0, 2000.0), "specs": specs})
	if (p["items"] as Array).is_empty():
		return {"ok": false, "why": "None of that process's parts are things this game knows."}
	if d.get("conns") is Array:
		for c in d["conns"]:
			if not (c is Dictionary) or (p["conns"] as Array).size() >= MAX_CONNS:
				continue
			if not seen.has(str(c.get("source_item_id", ""))) or not seen.has(str(c.get("target_item_id", ""))):
				continue
			var cc := {}
			for k in ["polarity", "resource_type", "source_item_id", "source_handle_id", "target_item_id", "target_handle_id", "data_kind", "flow_width"]:
				if c.has(k):
					cc[k] = str(c[k]).substr(0, 80)
			(p["conns"] as Array).append(cc)
	if d.get("logic") is Array:
		for b in d["logic"]:
			if b is Dictionary and (p["logic"] as Array).size() < MAX_LOGIC and str(b.get("kind", "")) in ScadaLogic.KINDS \
					and not str(b.get("id", "")).is_empty() and SimkitGuard._shape_ok(b, 0) and _inside(b, seen):
				(p["logic"] as Array).append((b as Dictionary).duplicate(true))
	var block_ids := {}
	for b in p["logic"]:
		block_ids[str(b["id"])] = true
	if d.get("alarms") is Array:
		for r in d["alarms"]:
			if not (r is Dictionary) or (p["alarms"] as Array).size() >= MAX_ALARMS or str(r.get("id", "")).is_empty():
				continue
			var tag := str(r.get("tag", ""))
			var bits := tag.split(".")
			if seen.has(tag_item(tag)) or (bits.size() > 1 and str(bits[0]) == "logic" and block_ids.has(str(bits[1]))):
				var rr := ScadaAlarms.make(str(r["id"]).substr(0, 40), str(r.get("name", "")).substr(0, 80), tag, str(r.get("op", ">=")), float(r.get("limit", 0.0)), str(r.get("priority", "medium")))
				rr["deadband"] = clampf(float(r.get("deadband", 0.0)), 0.0, 1.0e6)
				rr["delay_s"] = clampf(float(r.get("delay_s", 0.0)), 0.0, 86400.0)
				(p["alarms"] as Array).append(rr)
	if d.get("widgets") is Array:
		for w in d["widgets"]:
			if w is Dictionary and (p["widgets"] as Array).size() < MAX_WIDGETS and seen.has(tag_item(str(w.get("tag", "")))):
				var ww := MimicWidgets.normalized(w)
				ww["screen"] = ""
				(p["widgets"] as Array).append(ww)
	return {"ok": true, "pack": p, "why": ""}


## Every item tag in `v` names a part of the pack (a block that reaches
## outside it is dropped: it would drive something of the receiver's).
static func _inside(v: Variant, ids: Dictionary) -> bool:
	var tags: Array = []
	_tags_in(v, tags)
	for t in tags:
		if not ids.has(tag_item(str(t))):
			return false
	return true


## New ids for everything, tags rewritten. `new_item_id` / `new_block_id` /
## `new_alarm_id` / `new_widget_id` are Callables() -> String that never
## repeat; `at` = where its middle goes on the canvas.
## → {items, conns, logic, alarms, widgets, ids {old: new}}
static func instantiate(pack: Dictionary, at: Vector2, scope: String, new_item_id: Callable, new_block_id: Callable, new_alarm_id: Callable, new_widget_id: Callable) -> Dictionary:
	var ids := {}
	var out := {"items": [], "conns": [], "logic": [], "alarms": [], "widgets": [], "ids": ids}
	for it in pack.get("items", []):
		var nid := str(new_item_id.call())
		ids[str(it["id"])] = nid
		var ni: Dictionary = (it as Dictionary).duplicate(true)
		ni["id"] = nid
		ni["x"] = float(it.get("x", 0.0)) + at.x
		ni["y"] = float(it.get("y", 0.0)) + at.y
		ni["scope_id"] = scope
		ni["is_virtual"] = false
		if float(ni.get("width", 0.0)) <= 0.0:
			ni.erase("width")
		if float(ni.get("height", 0.0)) <= 0.0:
			ni.erase("height")
		(out["items"] as Array).append(ni)
	for c in pack.get("conns", []):
		var nc: Dictionary = (c as Dictionary).duplicate(true)
		nc["source_item_id"] = ids[str(c["source_item_id"])]
		nc["target_item_id"] = ids[str(c["target_item_id"])]
		nc["scope_id"] = scope
		(out["conns"] as Array).append(nc)
	var block_ids := {}
	for b in pack.get("logic", []):
		var nb: Dictionary = ScadaLogicRun.remap([b], ids)[0]
		var bid := str(new_block_id.call())
		block_ids[str(b["id"])] = bid
		nb["id"] = bid
		(out["logic"] as Array).append(nb)
	for r in pack.get("alarms", []):
		var nr: Dictionary = ScadaLogicRun.remap([r], ids)[0]
		var bits := str(nr.get("tag", "")).split(".")
		if bits.size() > 1 and str(bits[0]) == "logic" and block_ids.has(str(bits[1])):
			bits[1] = block_ids[str(bits[1])]
			nr["tag"] = ".".join(bits)
		nr["id"] = str(new_alarm_id.call())
		(out["alarms"] as Array).append(nr)
	for w in pack.get("widgets", []):
		var nw: Dictionary = ScadaLogicRun.remap([w], ids)[0]
		nw["id"] = str(new_widget_id.call())
		(out["widgets"] as Array).append(nw)
	return out


static func encode(pack: Dictionary) -> String:
	var raw := JSON.stringify(pack).to_utf8_buffer()
	return PREFIX + Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_GZIP)) + ":%d" % raw.size()


## → {ok, pack, why}. Takes a share code or a `.simproc` file's text (the
## same code, or plain JSON).
static func decode(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {"ok": false, "why": "Nothing to read."}
	if t.length() > MAX_BYTES * 2:
		return {"ok": false, "why": "That is too big to be a process."}
	var json := ""
	if t.begins_with(PREFIX):
		var body := t.substr(PREFIX.length())
		var cut := body.rfind(":")
		if cut <= 0 or not body.substr(cut + 1).is_valid_int():
			return {"ok": false, "why": "That share code is cut short."}
		var size := body.substr(cut + 1).to_int()
		if size <= 0 or size > MAX_BYTES:
			return {"ok": false, "why": "That share code is damaged."}
		var packed := Marshalls.base64_to_raw(body.substr(0, cut))
		if packed.is_empty():
			return {"ok": false, "why": "That share code is damaged."}
		var raw := packed.decompress(size, FileAccess.COMPRESSION_GZIP)
		if raw.size() != size:
			return {"ok": false, "why": "That share code is damaged."}
		json = raw.get_string_from_utf8()
	elif t.begins_with("{"):
		json = t
	else:
		return {"ok": false, "why": "That is not a process share code (they start with %s)." % PREFIX}
	var parser := JSON.new()
	if parser.parse(json) != OK:
		return {"ok": false, "why": "That share code is damaged."}
	return clean(parser.data)


## One line on what is in it.
static func describe(pack: Dictionary) -> String:
	var bits: Array = [UiText.count((pack.get("items", []) as Array).size(), "part")]
	if not (pack.get("logic", []) as Array).is_empty():
		bits.append(UiText.count((pack["logic"] as Array).size(), "control block"))
	if not (pack.get("alarms", []) as Array).is_empty():
		bits.append(UiText.count((pack["alarms"] as Array).size(), "alarm"))
	if not (pack.get("widgets", []) as Array).is_empty():
		bits.append(UiText.count((pack["widgets"] as Array).size(), "widget"))
	return ", ".join(bits)


# ── built-in templates ──────────────────────────────────────────────────────

const TEMPLATES := [
	["level_band", "Tank kept full (on / off)", "A supply, a fill valve and a day tank with an outlet. An on / off block opens the valve at 40 % and shuts it at 80 %; a high and a low alarm watch the tank."],
	["level_pid", "Tank held at a level (PID)", "The same line with a control valve. A PID loop holds the day tank at 50 %; a gauge and a trend show it."],
	["pump_transfer", "Pump with dry-run and overfill guards", "A pump lifts water from a low tank to a high one. One interlock stops it when the source runs low, another when the target is nearly full."],
]


static func _tank(id: String, tank_name: String, x: float, litres: float, level: float) -> Dictionary:
	return {"id": id, "type": "resource", "x": x, "y": 0.0, "specs": {"name": tank_name, "resource_kind": "water",
		"capacity_qty": litres, "capacity_unit": "L", "level": level}}


static func _pipe(a: String, b: String, a_tank: bool, b_tank: bool) -> Dictionary:
	return {"polarity": "resource", "resource_type": "water", "source_item_id": a, "source_handle_id": "output" if a_tank else "res_out_0",
		"target_item_id": b, "target_handle_id": "input" if b_tank else "res_in_0"}


static func template(id: String) -> Dictionary:
	var p := empty()
	for t in TEMPLATES:
		if str(t[0]) == id:
			p["name"] = str(t[1])
			p["note"] = str(t[2])
	match id:
		"level_band", "level_pid":
			var pid := id == "level_pid"
			p["items"] = [_tank("src", "Supply", -360.0, 20000.0, 0.8),
				{"id": "fv", "type": "processor", "x": -180.0, "y": 0.0, "specs": FlowCtl.make_specs("Fill valve", FlowCtl.KIND_VALVE, "water", 600.0, {"throttle": pid})},
				_tank("day", "Day tank", 0.0, 1000.0, 0.5),
				{"id": "ov", "type": "processor", "x": 180.0, "y": 0.0, "specs": FlowCtl.make_specs("Outlet", FlowCtl.KIND_VALVE, "water", 200.0)},
				_tank("use", "To use", 360.0, 50000.0, 0.0)]
			p["conns"] = [_pipe("src", "fv", true, false), _pipe("fv", "day", false, true), _pipe("day", "ov", true, false), _pipe("ov", "use", false, true)]
			if pid:
				p["logic"] = [ScadaLogic.template("hold_level_pid", "b1", {"pv": "tank.day.level", "out": "valve.fv.open"})]
				p["widgets"] = [
					{"id": "w1", "kind": "gauge", "x": 0.0, "y": -260.0, "w": 180.0, "h": 144.0, "tag": "tank.day.level", "label": "Day tank"},
					{"id": "w2", "kind": "trend", "x": 260.0, "y": -260.0, "w": 288.0, "h": 132.0, "tag": "tank.day.level", "label": "Day tank level"}]
			else:
				p["logic"] = [ScadaLogic.template("hold_level_band", "b1", {"pv": "tank.day.level", "out": "node.fv"})]
				(p["logic"][0] as Dictionary).merge({"low": 40.0, "high": 80.0}, true)
			p["alarms"] = [ScadaAlarms.make("a1", "Day tank high", "tank.day.level", ">=", 92.0, "high"),
				ScadaAlarms.make("a2", "Day tank low", "tank.day.level", "<=", 15.0, "medium")]
			for a in p["alarms"]:
				a["deadband"] = 2.0
				a["delay_s"] = 60.0
		"pump_transfer":
			p["items"] = [_tank("low", "Source tank", -240.0, 5000.0, 0.7),
				{"id": "pm", "type": "processor", "x": 0.0, "y": 0.0, "specs": FlowCtl.make_specs("Transfer pump", FlowCtl.KIND_PUMP, "water", 900.0, {"watts": 250.0})},
				_tank("high", "Header tank", 240.0, 2000.0, 0.2)]
			p["conns"] = [_pipe("low", "pm", true, false), _pipe("pm", "high", false, true)]
			p["logic"] = [ScadaLogic.template("dry_run", "b1", {"pv": "tank.low.level", "out": "node.pm"}),
				ScadaLogic.template("overfill", "b2", {"pv": "tank.high.level", "out": "node.pm"})]
			p["alarms"] = [ScadaAlarms.make("a1", "Source tank low", "tank.low.level", "<=", 10.0, "medium")]
	return p
