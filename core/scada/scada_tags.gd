class_name ScadaTags
extends RefCounted
## ONE tag list for the process designer (plans/SCADA_PROCESS_PLAN.md, Phase 1).
##
## A TAG is a named value somewhere on the site that a mimic can show, a rule
## can read, an alarm can watch and (when writable) a control block can
## command:
##
##   {id, label, group, unit, kind, value, text, available, writable,
##    source, item, lo, hi}
##
##   kind    "sensor" (a number) | "binary" (on / off, read only) |
##           "switch" (on / off, writable) | "number" (a writable number)
##   value   float; a binary / switch is 1.0 or 0.0; NAN = unavailable
##   text    what to print when the value is not just a number ("blocked")
##   source  "graph" | "site" | "esp" | "tc" | "ha"
##   item    the graph item behind it ("" = none)
##
## Tag IDS ARE the keys automations already use (`tank.<id>.level`,
## `node.<id>`, `sensor.battery_level`, `greenhouse.<id>.temp`) and, for a
## board, its Home Assistant entity id. Nothing that reads those keys changes.
##
## Pure: the collectors take plain data (a GraphModel, dictionaries) so the
## selftest builds them under --script. The live half that gathers from the
## scene is ScadaHub.

const KIND_SENSOR := "sensor"
const KIND_BINARY := "binary"
const KIND_SWITCH := "switch"
const KIND_NUMBER := "number"

const SOURCE_GRAPH := "graph"
const SOURCE_SITE := "site"
const SOURCE_ESP := "esp"
const SOURCE_TC := "tc"
const SOURCE_HA := "ha"
const SOURCE_LOGIC := "logic"
const SOURCE_ALARM := "alarm"

## Graph item types whose run switch is a tag.
const SWITCHABLE := ["processor", "appliance", "acload"]

## id -> tag, insertion order = display order.
var by_id: Dictionary = {}


static func make(id: String, label: String, unit: String, kind: String, value: float, opts: Dictionary = {}) -> Dictionary:
	var t := {
		"id": id, "label": label, "unit": unit, "kind": kind,
		"value": value, "text": str(opts.get("text", "")),
		"available": not is_nan(value) if not opts.has("available") else bool(opts["available"]),
		"writable": kind == KIND_SWITCH or kind == KIND_NUMBER,
		"source": str(opts.get("source", SOURCE_GRAPH)),
		"group": str(opts.get("group", "")),
		"item": str(opts.get("item", "")),
	}
	if opts.has("lo"):
		t["lo"] = float(opts["lo"])
	if opts.has("hi"):
		t["hi"] = float(opts["hi"])
	if opts.has("alias"):
		t["alias"] = str(opts["alias"])
	return t


## lower_snake_case of a display name: the alias automations accept in place
## of an id (get_automation_resource_context's own rule).
static func slug(name: String) -> String:
	return name.strip_edges().to_lower().replace(" ", "_")


static func is_bool_kind(kind: String) -> bool:
	return kind == KIND_BINARY or kind == KIND_SWITCH


## Tags of a graph, read straight off the item dicts (the flow engine stamps
## them): tank level and stock, each switchable node's state, each resource
## wire's flow, each greenhouse's air.
static func graph_tags(model: Object) -> Array:
	var out: Array = []
	if model == null:
		return out
	for item: Dictionary in model.get("items"):
		var ty := str(item.get("type", ""))
		var iid := str(item.get("id", ""))
		if iid.is_empty():
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var nm := str(specs.get("name", "")).strip_edges()
		if nm.is_empty():
			nm = iid
		if ty == "resource":
			var lvl := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
			out.append(make("tank.%s.level" % iid, "Level", "%", KIND_SENSOR, lvl * 100.0,
					{"group": nm, "item": iid, "lo": 0.0, "hi": 100.0,
					"alias": "tank.%s.level" % slug(nm)}))
			if not bool(specs.get("unlimited_capacity", false)):
				var cap := float(specs.get("capacity_qty", 0.0))
				out.append(make("tank.%s.stock" % iid, "Amount", str(specs.get("capacity_unit", "")),
						KIND_SENSOR, lvl * cap,
						{"group": nm, "item": iid, "lo": 0.0, "hi": cap}))
			out.append(make("tank.%s" % iid, "Overflowing", "", KIND_BINARY,
					1.0 if bool(specs.get("overflowing", false)) else 0.0,
					{"group": nm, "item": iid,
					"text": "overflow" if bool(specs.get("overflowing", false)) else "ok",
					"alias": "tank.%s" % slug(nm)}))
		elif ty in SWITCHABLE:
			var on := str(specs.get("requested_state", specs.get("current_state", "off"))).to_lower() == "on"
			var st := str(specs.get("node_state", ""))
			var word := "on" if on else "off"
			if st == "starved" or st == "blocked":
				word = st
			out.append(make("node.%s" % iid, "Running", "", KIND_SWITCH, 1.0 if on else 0.0,
					{"group": nm, "item": iid, "text": word, "alias": "node.%s" % slug(nm)}))
			# A control valve's (or a variable pump's) opening is a number a
			# loop can drive.
			if str(specs.get("role", "")) == "flowctl" and bool(specs.get("throttle", false)):
				out.append(make("valve.%s.open" % iid, "Opening", "%", KIND_NUMBER,
						clampf(float(specs.get("open", 1.0)), 0.0, 1.0) * 100.0,
						{"group": nm, "item": iid, "lo": 0.0, "hi": 100.0, "alias": "valve.%s.open" % slug(nm)}))
		elif ty == "compound" and bool(specs.get("greenhouse_system", false)) and specs.has("gh_t_air"):
			var g := {"group": nm, "item": iid}
			for row in [["temp", "Air temperature", "°C", "gh_t_air"], ["rh", "Humidity", "%", "gh_rh"],
					["dli", "Light today", "mol/m²", "gh_dli"], ["vent", "Vents open", "%", "gh_vent_pct"],
					["water_temp", "Water temperature", "°C", "gh_t_water"]]:
				var o := g.duplicate()
				o["alias"] = "greenhouse.%s.%s" % [slug(nm), row[0]]
				out.append(make("greenhouse.%s.%s" % [iid, row[0]], str(row[1]), str(row[2]),
						KIND_SENSOR, float(specs.get(str(row[3]), 0.0)), o))
			var frost := bool(specs.get("gh_frost", false))
			var fo := g.duplicate()
			fo["text"] = "on" if frost else "off"
			fo["alias"] = "greenhouse.%s.frost" % slug(nm)
			out.append(make("greenhouse.%s.frost" % iid, "Frost", "", KIND_BINARY, 1.0 if frost else 0.0, fo))
	for conn: Dictionary in model.get("connections"):
		var kind := str(conn.get("resource_type", ""))
		if kind.is_empty() or not conn.has("flow_rate"):
			continue
		var cid := str(conn.get("id", ""))
		out.append(make("wire.%s.flow" % cid, "Flow", "/h", KIND_SENSOR, float(conn.get("flow_rate", 0.0)),
				{"group": "%s line" % kind.capitalize(), "item": cid}))
	return out


## Site energy readings. `d` = {battery_pct, solar_w, load_w} (missing = left out).
static func site_tags(d: Dictionary) -> Array:
	var out: Array = []
	var o := {"group": "Site power", "source": SOURCE_SITE}
	if d.has("battery_pct"):
		var b := o.duplicate()
		b["lo"] = 0.0
		b["hi"] = 100.0
		out.append(make("sensor.battery_level", "Battery", "%", KIND_SENSOR, float(d["battery_pct"]), b))
	if d.has("solar_w"):
		out.append(make("sensor.solar_power", "Solar", "W", KIND_SENSOR, float(d["solar_w"]), o))
	if d.has("load_w"):
		out.append(make("sensor.load_power", "Load", "W", KIND_SENSOR, float(d["load_w"]), o))
		out.append(make("sensor.total_ac_load", "AC load", "W", KIND_SENSOR, float(d["load_w"]), o))
	return out


## A placed board's entities. `entities` = EspDesign's list, `latest` =
## EspLabRuntime.latest ({entity_id: {value, text, available}}).
static func esp_tags(board_name: String, entities: Array, latest: Dictionary) -> Array:
	var out: Array = []
	for e in entities:
		if not (e is Dictionary):
			continue
		var eid := str(e.get("entity_id", ""))
		if eid.is_empty():
			continue
		var dom := eid.get_slice(".", 0)
		var kind := KIND_SENSOR
		if dom == "binary_sensor":
			kind = KIND_BINARY
		elif dom == "switch" or dom == "light":
			kind = KIND_SWITCH
		elif dom == "number":
			kind = KIND_NUMBER
		var l: Dictionary = latest.get(eid, {}) as Dictionary
		var v := float(l.get("value", NAN))
		var ok := bool(l.get("available", false)) and not is_nan(v)
		if is_bool_kind(kind) and ok:
			v = 1.0 if v >= 0.5 else 0.0
		var t := make(eid, str(e.get("name", eid)), str(e.get("unit", "")), kind, v if ok else NAN,
				{"group": board_name, "source": SOURCE_ESP, "available": ok})
		# A board's switch follows what it is wired to until Phase 7 lets it act.
		t["writable"] = false
		out.append(t)
	return out


## Sensors and actuators of a tri-clamp process (TcProcControl's lists with
## their current values: [{key, label, unit, value}] / [{key, label, kind
## "switch" | "number", value}]).
static func tc_tags(design_name: String, sensors: Array, actuators: Array) -> Array:
	var out: Array = []
	for s in sensors:
		if s is Dictionary:
			out.append(make(str(s.get("key", "")), str(s.get("label", "")), str(s.get("unit", "")),
					KIND_SENSOR, float(s.get("value", NAN)), {"group": design_name, "source": SOURCE_TC}))
	for a in actuators:
		if a is Dictionary:
			var k := KIND_NUMBER if str(a.get("kind", "switch")) == "number" else KIND_SWITCH
			out.append(make(str(a.get("key", "")), str(a.get("label", "")), str(a.get("unit", "")),
					k, float(a.get("value", NAN)), {"group": design_name, "source": SOURCE_TC}))
	return out


## Followed Home Assistant entities ({entity_id: raw state string}).
static func ha_tags(states: Dictionary) -> Array:
	var out: Array = []
	for eid in states:
		var raw := str(states[eid])
		var low := raw.to_lower()
		if raw.is_valid_float():
			out.append(make(str(eid), str(eid), "", KIND_SENSOR, raw.to_float(),
					{"group": "Home Assistant", "source": SOURCE_HA}))
		elif low in ["on", "off", "open", "closed", "home", "not_home"]:
			out.append(make(str(eid), str(eid), "", KIND_BINARY,
					1.0 if low in ["on", "open", "home"] else 0.0,
					{"group": "Home Assistant", "source": SOURCE_HA, "text": raw}))
	return out


# ── the registry ────────────────────────────────────────────────────────────

func set_all(tags: Array) -> void:
	by_id.clear()
	add_all(tags)


## Earlier tags win on an id clash (the sim's own keys before HA's).
func add_all(tags: Array) -> void:
	for t in tags:
		if t is Dictionary and not str(t.get("id", "")).is_empty() and not by_id.has(t["id"]):
			by_id[t["id"]] = t


func has(id: String) -> bool:
	return by_id.has(id)


func tag(id: String) -> Dictionary:
	return by_id.get(id, {}) as Dictionary


## Current value; NAN when unknown or unavailable.
func value(id: String) -> float:
	var t: Dictionary = by_id.get(id, {}) as Dictionary
	if t.is_empty() or not bool(t.get("available", false)):
		return NAN
	return float(t.get("value", NAN))


func ids() -> Array:
	return by_id.keys()


func all() -> Array:
	return by_id.values()


## Tags matching every word of `query` (id, label, group, unit), in order.
func search(query: String, only_writable: bool = false) -> Array:
	var words := query.to_lower().split(" ", false)
	var out: Array = []
	for t: Dictionary in by_id.values():
		if only_writable and not bool(t.get("writable", false)):
			continue
		var hay := ("%s %s %s %s" % [t["id"], t["label"], t["group"], t["unit"]]).to_lower()
		var ok := true
		for w in words:
			if hay.find(w) < 0:
				ok = false
				break
		if ok:
			out.append(t)
	return out


## The value as a player reads it: "62 %", "on", "blocked", "unavailable".
static func display(t: Dictionary) -> String:
	if t.is_empty() or not bool(t.get("available", false)):
		return "unavailable"
	var txt := str(t.get("text", ""))
	if not txt.is_empty():
		return txt
	var v := float(t.get("value", 0.0))
	if is_bool_kind(str(t.get("kind", ""))):
		return "on" if v >= 0.5 else "off"
	var u := str(t.get("unit", ""))
	var s := UiText.num(v, "", 3)
	return s if u.is_empty() else "%s %s" % [s, u]


## The automation context: {numeric_values, device_states}, each tag under its
## id and its name alias. Binary / switch tags are STATES ("on" / "off" or
## their own word); everything else is a number.
static func context(tags: Array) -> Dictionary:
	var numeric: Dictionary = {}
	var states: Dictionary = {}
	for t in tags:
		if not (t is Dictionary) or not bool(t.get("available", false)):
			continue
		var keys: Array = [str(t["id"])]
		if t.has("alias"):
			keys.append(str(t["alias"]))
		if is_bool_kind(str(t["kind"])):
			var word := str(t.get("text", ""))
			if word.is_empty():
				word = "on" if float(t["value"]) >= 0.5 else "off"
			for k in keys:
				states[k] = word
		else:
			for k in keys:
				numeric[k] = float(t["value"])
	return {"numeric_values": numeric, "device_states": states}


## A control block's own tags (ScadaLogic.tags rows) as tags.
static func logic_tags(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		if not (r is Dictionary):
			continue
		var t := make(str(r.get("id", "")), str(r.get("label", "")), str(r.get("unit", "")),
				KIND_BINARY if str(r.get("kind", "")) == "binary" else KIND_SENSOR, float(r.get("value", NAN)),
				{"group": "Logic: %s" % str(r.get("group", "")), "source": SOURCE_LOGIC})
		t["writable"] = false
		out.append(t)
	return out


## An alarm rule's own tag (ScadaAlarms.tags rows) as tags.
static func alarm_tags(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		if not (r is Dictionary):
			continue
		var t := make(str(r.get("id", "")), str(r.get("label", "")), "", KIND_BINARY, float(r.get("value", NAN)),
				{"group": "Alarm: %s" % str(r.get("group", "")), "source": SOURCE_ALARM})
		t["writable"] = false
		out.append(t)
	return out
