class_name ProcessChallenge
extends RefCounted

## Challenge conditions on tags and alarms (pure). SCADA plan, Phase 9. A
## ChallengeDef's `process` dict, judged each evaluation of a realtime run on
## the player's own site, so it names no item: it works on whatever stores
## the player has put alarms on ("watched" stores).
##
##   min_alarm_rules       the site must have this many alarm rules (start and end)
##   max_unacked_alarm_h   fail when one alarm flashes unacknowledged this long
##   max_in_alarm_h        fail when alarms have been active this long in all
##   watch_lo / watch_hi   a watched store's level must stay inside (%)
##   watch_grace_h         … it may be outside this long before it fails
##
## step(state, cfg, rules, status, read, dt_h) → {state, fail, note}

const REASONS := {
	"process_no_alarms": "The site needs alarm rules on its stores before this watch can start (Process lens, Alarms, Suggest for this site).",
	"process_alarm_ignored": "An alarm was left flashing for too long: nobody acknowledged it.",
	"process_in_alarm": "The plant spent too long in alarm.",
	"process_store_out": "A watched store ran outside its limits for too long.",
}


static func is_reason(reason: String) -> bool:
	return REASONS.has(reason)


static func reason_label(reason: String) -> String:
	return str(REASONS.get(reason, reason))


## The stores the player watches: every "tank.<id>.level" an alarm rule reads.
static func watched_tags(rules: Array) -> Array:
	var out: Array = []
	for r in rules:
		var tag := str((r as Dictionary).get("tag", ""))
		if tag.begins_with("tank.") and tag.ends_with(".level") and bool(r.get("enabled", true)) and not out.has(tag):
			out.append(tag)
	return out


## "" when the run may start / may be won, else the reason it may not.
static func gate(cfg: Dictionary, rules: Array) -> String:
	var need := int(cfg.get("min_alarm_rules", 0))
	if need > 0:
		var n := 0
		for r in rules:
			if bool((r as Dictionary).get("enabled", true)):
				n += 1
		if n < need:
			return "process_no_alarms"
	return ""


static func step(state: Dictionary, cfg: Dictionary, rules: Array, status: Dictionary, read: Callable, dt_h: float) -> Dictionary:
	var st := state.duplicate(true)
	var dt := clampf(dt_h, 0.0, 0.5)   # a jump is not judged
	var fail := ""
	var note := ""
	# Unacknowledged alarms: each its own running time.
	var unack: Dictionary = st.get("unack", {}) as Dictionary
	var any_active := false
	for id in status:
		var s := str((status[id] as Dictionary).get("state", "normal"))
		if s == "unack":
			unack[id] = float(unack.get(id, 0.0)) + dt
		else:
			unack.erase(id)
		if bool((status[id] as Dictionary).get("active", false)):
			any_active = true
	for id in unack.keys():
		if not status.has(id):
			unack.erase(id)
	st["unack"] = unack
	var max_unack := float(cfg.get("max_unacked_alarm_h", -1.0))
	if max_unack >= 0.0:
		for id in unack:
			if float(unack[id]) > max_unack + 1e-9:
				fail = "process_alarm_ignored"
	if any_active:
		st["in_alarm_h"] = float(st.get("in_alarm_h", 0.0)) + dt
	var max_alarm := float(cfg.get("max_in_alarm_h", -1.0))
	if fail.is_empty() and max_alarm >= 0.0 and float(st.get("in_alarm_h", 0.0)) > max_alarm + 1e-9:
		fail = "process_in_alarm"
	# Watched stores inside their band.
	if cfg.has("watch_lo") or cfg.has("watch_hi"):
		var lo := float(cfg.get("watch_lo", 0.0))
		var hi := float(cfg.get("watch_hi", 100.0))
		var grace := float(cfg.get("watch_grace_h", 0.0))
		var out_h: Dictionary = st.get("out", {}) as Dictionary
		var tags := watched_tags(rules)
		for tag in tags:
			var v := float(read.call(tag))
			if is_nan(v):
				continue
			if v < lo - 1e-6 or v > hi + 1e-6:
				out_h[tag] = float(out_h.get(tag, 0.0)) + dt
				if fail.is_empty() and float(out_h[tag]) > grace + 1e-9:
					fail = "process_store_out"
			else:
				out_h.erase(tag)
		for tag in out_h.keys():
			if not tags.has(tag):
				out_h.erase(tag)
		st["out"] = out_h
		if not out_h.is_empty():
			note = "%s outside its limits" % UiText.count(out_h.size(), "store")
	if note.is_empty() and not unack.is_empty():
		note = "%s waiting to be acknowledged" % UiText.count(unack.size(), "alarm")
	return {"state": st, "fail": fail, "note": note}
