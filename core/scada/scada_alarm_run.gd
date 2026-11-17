class_name ScadaAlarmRun
extends RefCounted

## Alarm rules judged over a run with nobody to acknowledge them (simkit, A/B
## worlds): how often each went off and for how long. SCADA plan, Phase 9.
##   var a := ScadaAlarmRun.from_rules(rules)
##   a.step(func(tag) -> float, now_h)   each sim step
##   a.summary() → [{id, name, tag, raised, active_h}]

var rules: Array = []
var state: Dictionary = {}
var raised: Dictionary = {}       # id -> times it went off
var active_h: Dictionary = {}     # id -> hours in alarm
var _last_h := NAN


static func from_rules(rules_in: Variant) -> ScadaAlarmRun:
	var r := ScadaAlarmRun.new()
	if rules_in is Array:
		for x in rules_in:
			if x is Dictionary and not str((x as Dictionary).get("id", "")).is_empty() and not str(x.get("tag", "")).is_empty():
				var rule := ScadaAlarms.make(str(x["id"]), str(x.get("name", x["id"])), str(x["tag"]), str(x.get("op", ">=")), float(x.get("limit", 0.0)), str(x.get("priority", "medium")))
				rule["deadband"] = float(x.get("deadband", 0.0))
				rule["delay_s"] = float(x.get("delay_s", 0.0))
				r.rules.append(rule)
	return r


func is_empty() -> bool:
	return rules.is_empty()


func step(read: Callable, now_h: float) -> void:
	if rules.is_empty():
		return
	var res := ScadaAlarms.step(rules, state, read, now_h)
	state = res["state"]
	var dt := (now_h - _last_h) if not is_nan(_last_h) and now_h > _last_h and now_h - _last_h <= 0.5 else 0.0
	_last_h = now_h
	for e in res["events"]:
		if str((e as Dictionary).get("what", "")) == "raised":
			var id := str(e.get("id", ""))
			raised[id] = int(raised.get(id, 0)) + 1
	var status: Dictionary = res["status"]
	for id in status:
		if bool((status[id] as Dictionary).get("active", false)):
			active_h[id] = float(active_h.get(id, 0.0)) + dt
			# Nobody is there to acknowledge: count it as seen, so the next
			# time it goes off is a new alarm.
			state = ScadaAlarms.command(state, str(id), "ack", now_h)


func summary() -> Array:
	var out: Array = []
	for r in rules:
		var id := str(r["id"])
		out.append({"id": id, "name": str(r["name"]), "tag": str(r["tag"]), "raised": int(raised.get(id, 0)), "active_h": snappedf(float(active_h.get(id, 0.0)), 0.01)})
	return out
