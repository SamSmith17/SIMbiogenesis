class_name AutomationSim
extends RefCounted

## The graph's automations (the inspector's WHEN / IF / THEN cards, stored as
## specs.graph_automations on each load) evaluated in SIM TIME, between two
## instants — so a simulated day or week contains what they switch.
##
## Pure: no scene, no AutomationEngine. `step(t0, t1, ctx, apply)` decides
## what fired in (t0, t1] and calls apply(item_id, command) for every action;
## the caller writes its own model.
##
## Actions:
##   {kind: "scene_node", command: turn_on|turn_off|toggle, target?: String}
##       switch the rule's item, or with `target` one actuator ON it (one
##       heating element of a two-element reactor);
##   {kind: "set_value", entity_id, value}
##       set a number (an element's power, a valve's open fraction, a
##       cooling-water flow; HA's number. / input_number.set_value);
##   {kind: "delay", delay_seconds}.
## Command shapes handed to `apply`:
##   rich_commands false (the default, every caller written before set_value):
##       a plain scene_node action -> apply(item_id, "turn_on" ...), exactly
##       as before; a targeted one -> the same String (the caller has no
##       notion of targets, so it switches the item); set_value -> NOT applied
##       and not logged (counted in `skipped`), since such a caller cannot
##       hold a value.
##   rich_commands true: always apply(item_id, Dictionary) with
##       {cmd: "turn_on"|"turn_off"|"toggle", target: String} or
##       {cmd: "set_value", entity_id: String, value: float}.
##
## Semantics, chosen so the answer does not depend on the step size:
##   time / sun trigger   fires when its clock time is CROSSED in (t0, t1]
##                        (the live engine used a ±1 / ±5 min window, which a
##                        fast clock steps over);
##   numeric trigger      fires on entering its range (above < v < below),
##                        after staying there `for_seconds` of SIM time;
##   state trigger        fires on a change to `to_state` (or any change),
##                        optionally from `from_state`, after `for_seconds`;
##   conditions           all must hold at t1;
##   delay action         the rest of the list runs `delay_seconds` of sim
##                        time later; while a rule waits it ignores new
##                        triggers (mode "single", as the engine registers).
## Like the live engine, a numeric trigger already in range at the first step
## fires then (the rule establishes its state).
##
## ctx: {numeric: {key: float}, states: {key: String}, sun: Vector2(sunrise,
## sunset) clock hours for t1's day, weekday: int (0 = Sunday, -1 unknown)}.
## Numeric keys follow the engine: sensor.battery_level (%),
## sensor.solar_power (W), sensor.load_power (W), tank.<id|name>.level (%).

var rules: Array = []      # [{item_id, alias, id, enabled, triggers, conditions, actions}]
## [{t, item_id, alias, command, target?, entity_id?, value?}] — every
## action applied, for the report.
var log: Array = []
## set_value actions that came due without rich_commands (nothing applied).
var skipped := 0
const LOG_MAX := 2000
## See the header: Dictionary commands for set_value and targeted actions.
var rich_commands := false

var _trig: Dictionary = {}     # "ri:ti" -> {last: bool, since: float, state: String}
var _pending: Array = []       # [{at, ri, ai}] action tails waiting on a delay
var _started := false


## Every enabled automation on every item of `model` (a GraphModel or
## anything with an `items` array).
static func from_model(model: Object) -> AutomationSim:
	var s := AutomationSim.new()
	if model == null:
		return s
	for it in model.get("items"):
		var item: Dictionary = it
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		s.add_specs(specs.get("graph_automations", []) as Array, str(item.get("id", "")))
	return s


## A sim over one automation list (the inspector's card specs) that all act
## on `item_id` — a design's own automations, say, with no graph around them.
static func from_specs(autos: Array, item_id: String = "") -> AutomationSim:
	var s := AutomationSim.new()
	s.add_specs(autos, item_id)
	return s


## Append every enabled automation spec in `autos` as a rule on `item_id`.
func add_specs(autos: Array, item_id: String) -> void:
	for a in autos:
		if not (a is Dictionary):
			continue
		var spec: Dictionary = a
		if not bool(spec.get("enabled", true)):
			continue
		rules.append({"item_id": item_id, "alias": str(spec.get("alias", "Automation")),
			"id": str(spec.get("id", "")), "triggers": spec.get("triggers", []),
			"conditions": spec.get("conditions", []), "actions": spec.get("actions", [])})


func is_empty() -> bool:
	return rules.is_empty()


## The between-steps state (triggers' memory, delayed tails, the log), so a
## model that keyframes itself can seek back and replay the same switches.
func snapshot() -> Dictionary:
	return {"trig": _trig.duplicate(true), "pending": _pending.duplicate(true), "started": _started,
		"log": log.duplicate(true), "skipped": skipped}


func restore(s: Dictionary) -> void:
	_trig = (s.get("trig", {}) as Dictionary).duplicate(true)
	_pending = (s.get("pending", []) as Array).duplicate(true)
	_started = bool(s.get("started", false))
	log = (s.get("log", []) as Array).duplicate(true)
	skipped = int(s.get("skipped", 0))


## Evaluate (t0, t1] (absolute hours). Returns how many actions were applied.
func step(t0: float, t1: float, ctx: Dictionary, apply: Callable) -> int:
	var n := 0
	# Delayed tails that came due.
	var due: Array = []
	var keep: Array = []
	for p in _pending:
		if float(p["at"]) <= t1 + 1e-9:
			due.append(p)
		else:
			keep.append(p)
	_pending = keep
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["at"]) < float(b["at"]))
	for p in due:
		n += _run_actions(int(p["ri"]), int(p["ai"]), float(p["at"]), apply)
	var first := not _started
	_started = true
	for ri in rules.size():
		var r: Dictionary = rules[ri]
		var fired := false
		var trigs: Array = r["triggers"]
		for ti in trigs.size():
			if _trigger_fires(ri, ti, trigs[ti] as Dictionary, t0, t1, ctx, first):
				fired = true
		if not fired or _busy(ri):
			continue
		if not _conditions_hold(r["conditions"] as Array, t1, ctx):
			continue
		n += _run_actions(ri, 0, t1, apply)
	return n


## Whether rule `ri` is waiting on a delay.
func _busy(ri: int) -> bool:
	for p in _pending:
		if int(p["ri"]) == ri:
			return true
	return false


func _run_actions(ri: int, from_ai: int, t: float, apply: Callable) -> int:
	var r: Dictionary = rules[ri]
	var acts: Array = r["actions"]
	var n := 0
	for ai in range(from_ai, acts.size()):
		var a: Dictionary = acts[ai]
		match str(a.get("kind", "scene_node")):
			"delay":
				var d := maxf(float(a.get("delay_seconds", 0.0)), 0.0) / 3600.0
				if d > 0.0:
					_pending.append({"at": t + d, "ri": ri, "ai": ai + 1})
					return n
			"scene_node":
				var cmd := str(a.get("command", "turn_on"))
				var target := str(a.get("target", ""))
				if apply.is_valid():
					if rich_commands:
						apply.call(str(r["item_id"]), {"cmd": cmd, "target": target})
					else:
						apply.call(str(r["item_id"]), cmd)
				n += 1
				var e := {"t": t, "item_id": r["item_id"], "alias": r["alias"], "command": cmd}
				if not target.is_empty():
					e["target"] = target
				_log(e)
			"set_value":
				var eid := str(a.get("entity_id", ""))
				var v := float(a.get("value", 0.0))
				var e2 := {"t": t, "item_id": r["item_id"], "alias": r["alias"],
					"command": "set_value", "entity_id": eid, "value": v}
				if rich_commands and not eid.is_empty():
					if apply.is_valid():
						apply.call(str(r["item_id"]), {"cmd": "set_value", "entity_id": eid, "value": v})
					n += 1
					_log(e2)
				else:
					skipped += 1
	return n


func _log(e: Dictionary) -> void:
	if log.size() < LOG_MAX:
		log.append(e)


func _trigger_fires(ri: int, ti: int, tr: Dictionary, t0: float, t1: float,
		ctx: Dictionary, first: bool) -> bool:
	var key := "%d:%d" % [ri, ti]
	var st: Dictionary = _trig.get(key, {"last": false, "since": NAN, "state": ""})
	var fires := false
	match str(tr.get("kind", "time")):
		"time":
			fires = not first and crossed(float(tr.get("at_hour", 12.0)), t0, t1)
		"sun":
			var sun: Vector2 = ctx.get("sun", Vector2(6.0, 18.0))
			var base := sun.x if str(tr.get("event", "sunset")) == "sunrise" else sun.y
			fires = not first and crossed(fposmod(base + float(tr.get("offset_hours", 0.0)), 24.0), t0, t1)
		"numeric":
			var v: Variant = (ctx.get("numeric", {}) as Dictionary).get(str(tr.get("entity_id", "")), null)
			var inside := false
			if v != null:
				inside = in_range(float(v), tr.get("above", null), tr.get("below", null))
			var held := _held(st, inside, t1, float(tr.get("for_seconds", 0.0)))
			fires = held and not bool(st["last"])
			st["last"] = held
		"state":
			var cur := str((ctx.get("states", {}) as Dictionary).get(str(tr.get("entity_id", "")), "unknown"))
			var prev := str(st["state"])
			var to := str(tr.get("to_state", ""))
			var frm := str(tr.get("from_state", ""))
			if cur != prev:
				st["since"] = t1
				st["from"] = prev
			var match_now := cur == to if not to.is_empty() else (cur != prev and not prev.is_empty())
			if match_now and not frm.is_empty():
				match_now = str(st.get("from", "")) == frm
			var fs := float(tr.get("for_seconds", 0.0))
			if match_now and fs > 0.0:
				match_now = not is_nan(float(st["since"])) and (t1 - float(st["since"])) * 3600.0 >= fs
			fires = match_now and not bool(st["last"]) if not to.is_empty() else match_now
			st["last"] = match_now
			st["state"] = cur
	_trig[key] = st
	return fires


## In range for `for_seconds` of sim time.
static func _held(st: Dictionary, inside: bool, t1: float, for_s: float) -> bool:
	if not inside:
		st["since"] = NAN
		return false
	if is_nan(float(st["since"])):
		st["since"] = t1
	return for_s <= 0.0 or (t1 - float(st["since"])) * 3600.0 >= for_s - 1e-6


static func in_range(v: float, above: Variant, below: Variant) -> bool:
	if above != null and v <= float(above):
		return false
	if below != null and v >= float(below):
		return false
	return true


## 0 = Sunday. Absolute day 0 (1 Jan of year 1, proleptic Gregorian) is a Monday.
static func weekday_of(abs_h: float) -> int:
	return (int(floor(abs_h / 24.0)) + 1) % 7


## Whether the daily clock time `h` (0..24) falls in (t0, t1] absolute hours.
static func crossed(h: float, t0: float, t1: float) -> bool:
	if t1 <= t0:
		return false
	var e := floorf((t1 - h) / 24.0) * 24.0 + h
	return e > t0 + 1e-9 and e <= t1 + 1e-9


func _conditions_hold(conds: Array, t1: float, ctx: Dictionary) -> bool:
	var tod := fposmod(t1, 24.0)
	for c_v in conds:
		var c: Dictionary = c_v
		match str(c.get("kind", "time")):
			"time":
				var a := float(c.get("after_hour", 0.0))
				var b := float(c.get("before_hour", 24.0))
				var inside := (tod >= a and tod < b) if a < b else (tod >= a or tod < b)
				if not inside:
					return false
				var wd: Array = c.get("weekdays", [])
				var today := int(ctx.get("weekday", -1))
				if not wd.is_empty() and today >= 0 and not (today in wd):
					return false
			"numeric":
				var v: Variant = (ctx.get("numeric", {}) as Dictionary).get(str(c.get("entity_id", "")), null)
				if v == null or not in_range(float(v), c.get("above", null), c.get("below", null)):
					return false
			"sun":
				var sun: Vector2 = ctx.get("sun", Vector2(6.0, 18.0))
				var day := tod >= sun.x and tod < sun.y
				if (str(c.get("state", "above_horizon")) == "above_horizon") != day:
					return false
			"state":
				var cur := str((ctx.get("states", {}) as Dictionary).get(str(c.get("entity_id", "")), "unknown"))
				var states: Array = c.get("states", [])
				if not states.is_empty() and not (cur in states):
					return false
	return true
