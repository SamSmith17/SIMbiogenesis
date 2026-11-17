class_name ScadaAlarms
extends RefCounted
## Alarms on tags (plans/SCADA_PROCESS_PLAN.md, Phase 5).
##
## A rule: {id, name, tag, op, limit, deadband, delay_s, priority, enabled}
##   op        ">=" | "<=" (a number against `limit`), "on" | "off" (a switch
##             or a yes / no tag), "lost" (the tag has no reading)
##   deadband  how far back past the limit the value must come before the
##             alarm clears (stops chatter at the limit)
##   delay_s   how long the condition must hold before it raises (sim time)
##   priority  "high" | "medium" | "low"
##
## States (ANSI/ISA-18.2-2016, the alarm state diagram, fig. 3):
##   "normal"    not in alarm, nothing to acknowledge
##   "unack"     in alarm, not yet acknowledged          (flashes)
##   "acked"     in alarm, acknowledged                  (steady)
##   "rtn"       back to normal before anyone acknowledged it (stays listed
##               until acknowledged)
##   "shelved"   put aside by the operator until a time; raises nothing
##
##   step(rules, state, read, now_h) → {state, status, events}
##     read    Callable(tag) -> float (NAN = no reading)
##     status  {rule id: {state, active, text, value, priority, since_h}}
##     events  [{id, what: "raised" | "cleared", h, name, priority, text}]
##
## A scrub back clears what is pending (nothing raises on a rewind); a step
## longer than MAX_DT_H restarts the delays.
##
## Each rule offers a tag, alarm.<id> (1 while in alarm and not shelved), so a
## control block can act on it.
##
## Pure and autoload-free.

const OPS := [">=", "<=", "on", "off", "lost"]
const OP_WORDS := {">=": "at or above", "<=": "at or below", "on": "is on", "off": "is off", "lost": "has no reading"}
const PRIORITIES := ["high", "medium", "low"]
const PRIORITY_RANK := {"high": 0, "medium": 1, "low": 2}
const PRIORITY_WORDS := {"high": "High", "medium": "Medium", "low": "Low"}
const MAX_DT_H := 0.5
const JOURNAL_MAX := 300


static func make(id: String, name: String, tag: String, op: String, limit: float, priority: String = "medium") -> Dictionary:
	return {"id": id, "name": name, "tag": tag, "op": op if op in OPS else ">=", "limit": limit, "deadband": 0.0,
		"delay_s": 0.0, "priority": priority if priority in PRIORITIES else "medium", "enabled": true}


## Whether the rule's condition holds for `v`. `was` = it was already in
## alarm (the deadband applies on the way back).
static func condition(rule: Dictionary, v: float, was: bool) -> bool:
	var op := str(rule.get("op", ">="))
	if op == "lost":
		return is_nan(v)
	if is_nan(v):
		return was   # no reading: hold what it was
	var lim := float(rule.get("limit", 0.0))
	var db := maxf(float(rule.get("deadband", 0.0)), 0.0) if was else 0.0
	match op:
		">=":
			return v >= lim - db
		"<=":
			return v <= lim + db
		"on":
			return v >= 0.5
		"off":
			return v < 0.5
	return false


static func step(rules: Array, state: Dictionary, read: Callable, now_h: float) -> Dictionary:
	var st: Dictionary = state.duplicate(true)
	var last := float(st.get("_last_h", NAN))
	var rewound := not is_nan(last) and now_h < last
	var jumped := not is_nan(last) and now_h - last > MAX_DT_H
	st["_last_h"] = now_h
	var status := {}
	var events: Array = []
	for r in rules:
		if not (r is Dictionary):
			continue
		var id := str(r.get("id", ""))
		var s: Dictionary = st.get(id, {}) as Dictionary
		var cur := str(s.get("state", "normal"))
		var pri := str(r.get("priority", "medium"))
		if not bool(r.get("enabled", true)) or str(r.get("tag", "")).is_empty():
			st[id] = {"state": "normal"}
			status[id] = {"state": "normal", "active": false, "text": "Off", "value": NAN, "priority": pri, "since_h": NAN}
			continue
		var v: float = read.call(str(r["tag"]))
		var in_alarm := cur == "unack" or cur == "acked"
		if cur == "shelved":
			if now_h >= float(s.get("until_h", 0.0)) or rewound:
				cur = "normal"
				s.erase("until_h")
			else:
				s["state"] = cur
				st[id] = s
				status[id] = {"state": "shelved", "active": false, "text": "Shelved", "value": v, "priority": pri, "since_h": NAN}
				continue
		var hit := condition(r, v, in_alarm)
		if rewound or jumped:
			s.erase("pending_h")
		if hit and not in_alarm:
			var delay_h := maxf(float(r.get("delay_s", 0.0)), 0.0) / 3600.0
			if not s.has("pending_h"):
				s["pending_h"] = now_h
			if now_h - float(s["pending_h"]) >= delay_h - 1e-9 and not rewound:
				cur = "unack"
				s["since_h"] = now_h
				s.erase("pending_h")
				events.append({"id": id, "what": "raised", "h": now_h, "name": str(r.get("name", id)), "priority": pri,
					"text": describe(r, v)})
		elif not hit:
			s.erase("pending_h")
			if cur == "unack":
				cur = "rtn"
				events.append({"id": id, "what": "cleared", "h": now_h, "name": str(r.get("name", id)), "priority": pri, "text": ""})
			elif cur == "acked":
				cur = "normal"
				events.append({"id": id, "what": "cleared", "h": now_h, "name": str(r.get("name", id)), "priority": pri, "text": ""})
		s["state"] = cur
		st[id] = s
		var active := cur == "unack" or cur == "acked"
		status[id] = {"state": cur, "active": active, "value": v, "priority": pri, "since_h": float(s.get("since_h", NAN)),
			"text": describe(r, v) if active else ("Back to normal, not acknowledged" if cur == "rtn" else "Normal")}
	return {"state": st, "status": status, "events": events}


## "Day tank level 96.2 (limit 95)".
static func describe(rule: Dictionary, v: float) -> String:
	var op := str(rule.get("op", ">="))
	if op == "lost":
		return "no reading"
	if op == "on" or op == "off":
		return "is %s" % op
	return "%s (limit %s)" % [_n(v), _n(float(rule.get("limit", 0.0)))]


## An operator's command. → the new state.
##   "ack": unack → acked, rtn → normal.   "shelve": aside until now + value h.
##   "unshelve".
static func command(state: Dictionary, id: String, what: String, now_h: float = 0.0, value: float = 1.0) -> Dictionary:
	var st: Dictionary = state.duplicate(true)
	var s: Dictionary = st.get(id, {}) as Dictionary
	var cur := str(s.get("state", "normal"))
	match what:
		"ack":
			if cur == "unack":
				s["state"] = "acked"
			elif cur == "rtn":
				s["state"] = "normal"
		"shelve":
			s["state"] = "shelved"
			s["until_h"] = now_h + maxf(value, 0.0)
			s.erase("pending_h")
		"unshelve":
			if cur == "shelved":
				s["state"] = "normal"
				s.erase("until_h")
	st[id] = s
	return st


static func ack_all(state: Dictionary, rules: Array) -> Dictionary:
	var st := state
	for r in rules:
		if r is Dictionary:
			st = command(st, str((r as Dictionary).get("id", "")), "ack")
	return st


## What needs showing, worst first: [{id, name, state, priority, text, tag}]
## for every rule that is in alarm or waiting to be acknowledged.
static func active_list(rules: Array, status: Dictionary) -> Array:
	var out: Array = []
	for r in rules:
		if not (r is Dictionary):
			continue
		var id := str(r.get("id", ""))
		var s: Dictionary = status.get(id, {}) as Dictionary
		var cur := str(s.get("state", "normal"))
		if cur in ["unack", "acked", "rtn"]:
			out.append({"id": id, "name": str(r.get("name", id)), "state": cur, "priority": str(r.get("priority", "medium")),
				"text": str(s.get("text", "")), "tag": str(r.get("tag", "")), "since_h": float(s.get("since_h", NAN))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ua := 0 if str(a["state"]) == "unack" else (1 if str(a["state"]) == "rtn" else 2)
		var ub := 0 if str(b["state"]) == "unack" else (1 if str(b["state"]) == "rtn" else 2)
		if ua != ub:
			return ua < ub
		var pa := int(PRIORITY_RANK.get(str(a["priority"]), 1))
		var pb := int(PRIORITY_RANK.get(str(b["priority"]), 1))
		if pa != pb:
			return pa < pb
		return str(a["id"]) < str(b["id"]))
	return out


## {active, unack, worst: "" | priority, text} for a chip or a bar.
static func summary(rules: Array, status: Dictionary) -> Dictionary:
	var list := active_list(rules, status)
	var active := 0
	var unack := 0
	var worst := ""
	for a in list:
		if str(a["state"]) != "rtn":
			active += 1
		if str(a["state"]) != "acked":
			unack += 1
		if worst.is_empty() or int(PRIORITY_RANK.get(str(a["priority"]), 1)) < int(PRIORITY_RANK.get(worst, 1)):
			worst = str(a["priority"])
	var text := "No alarms"
	if not list.is_empty():
		var first: Dictionary = list[0]
		text = "%s: %s" % [str(first["name"]), str(first["text"])]
		if list.size() > 1:
			text += "  (+%d more)" % (list.size() - 1)
	return {"active": active, "unack": unack, "worst": worst, "text": text, "count": list.size()}


## The rules' own tags: [{id, label, unit, kind, value, group}].
static func tags(rules: Array, status: Dictionary) -> Array:
	var out: Array = []
	for r in rules:
		if r is Dictionary:
			var id := str(r.get("id", ""))
			out.append({"id": "alarm.%s" % id, "label": "In alarm", "unit": "", "kind": "binary",
				"value": 1.0 if bool((status.get(id, {}) as Dictionary).get("active", false)) else 0.0, "group": str(r.get("name", id))})
	return out


## Starter rules for a site, from its tags: [{id, label, kind, …}] (ScadaTags
## rows). A store gets a high and a low level alarm, an interlock its trip.
## `have` = rules already there (a tag + op already covered is skipped).
static func suggest(tag_rows: Array, have: Array, next_id: Callable) -> Array:
	var covered := {}
	for r in have:
		if r is Dictionary:
			covered["%s|%s" % [str(r.get("tag", "")), str(r.get("op", ""))]] = true
	var out: Array = []
	for t in tag_rows:
		if not (t is Dictionary):
			continue
		var id := str(t.get("id", ""))
		var grp := str(t.get("group", id))
		if id.begins_with("tank.") and id.ends_with(".level"):
			if not covered.has(id + "|>="):
				var hi := make(str(next_id.call()), "%s nearly full" % grp, id, ">=", 95.0, "medium")
				hi["deadband"] = 2.0
				hi["delay_s"] = 60.0
				out.append(hi)
				covered[id + "|>="] = true
			if not covered.has(id + "|<="):
				var lo := make(str(next_id.call()), "%s nearly empty" % grp, id, "<=", 5.0, "medium")
				lo["deadband"] = 2.0
				lo["delay_s"] = 60.0
				out.append(lo)
				covered[id + "|<="] = true
		elif id.begins_with("logic.") and id.ends_with(".tripped"):
			if not covered.has(id + "|on"):
				out.append(make(str(next_id.call()), "%s tripped" % grp.trim_prefix("Logic: "), id, "on", 0.5, "high"))
				covered[id + "|on"] = true
		elif id == "sensor.battery_level":
			if not covered.has(id + "|<="):
				var b := make(str(next_id.call()), "Battery low", id, "<=", 20.0, "high")
				b["deadband"] = 3.0
				b["delay_s"] = 120.0
				out.append(b)
				covered[id + "|<="] = true
	return out


static func _n(v: float) -> String:
	if is_nan(v):
		return "?"
	return str(snappedf(v, 0.1)) if absf(v) < 100.0 else str(int(round(v)))
