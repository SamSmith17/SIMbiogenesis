class_name SiteDeploySchedule
extends RefCounted

## The site's DEPLOYMENT SCHEDULE — "set a time on the timeline and everyone
## builds (or packs up) everything". Pure static helpers over one plain
## record (the FireTimeline idiom: nothing here touches a node, so the
## selftest drives it offline and the director is the only impure half).
##
## Record (saved per world as WorldPaths kind "deploy_schedule"):
##   { version, next_id,
##     events: [ {id, action: "deploy"|"packup", at_h (absolute sim hours)} ],
##     fired:  { event_id: {at: abs_h fired, projects: [{iid, pid}],
##               items: [{kind, id}], pending: int} } }
##
## Semantics the director holds to:
##   - an event FIRES once, when the clock crosses `at_h` FORWARD
##     (`due`); the crew then does the work through Site Projects;
##   - scrubbing BACK past a fired event (`rewound`) undoes it instantly —
##     the crew's work cannot be reversed, so the world is put back as it was
##     before the event and the stamp cleared, which makes the next forward
##     crossing fire it again;
##   - moving an event clears its stamp for the same reason.

const VERSION := 1
const ACTION_DEPLOY := "deploy"
const ACTION_PACKUP := "packup"
const ACTIONS := [ACTION_DEPLOY, ACTION_PACKUP]

## Site phase names (phase_at): the site as the LAST event left it.
const PHASE_NONE := "unscheduled"
const PHASE_DEPLOYED := "deployed"
const PHASE_PACKED := "packed"


static func empty() -> Dictionary:
	return {"version": VERSION, "next_id": 1, "events": [], "fired": {}}


static func normalize(raw: Variant) -> Dictionary:
	var out := empty()
	if not (raw is Dictionary):
		return out
	var d := raw as Dictionary
	out["next_id"] = maxi(int(d.get("next_id", 1)), 1)
	for e in d.get("events", []):
		if not (e is Dictionary):
			continue
		var ed := e as Dictionary
		var action := str(ed.get("action", ""))
		var at: float = float(ed.get("at_h", NAN))
		var id := str(ed.get("id", ""))
		if not ACTIONS.has(action) or is_nan(at) or id.is_empty():
			continue
		(out["events"] as Array).append({"id": id, "action": action, "at_h": at})
		var n := int(id.trim_prefix("ev_"))
		out["next_id"] = maxi(int(out["next_id"]), n + 1)
	# The one-structure queue (SiteDeployDirector.queue_item) rides the file
	# under `manual`, shaped like an event's stamp.
	if d.get("manual", null) is Dictionary and not (d["manual"] as Dictionary).is_empty():
		out["manual"] = (d["manual"] as Dictionary).duplicate(true)
	var fired: Variant = d.get("fired", {})
	if fired is Dictionary:
		for k in (fired as Dictionary).keys():
			if (fired as Dictionary)[k] is Dictionary and event(out, str(k)).size() > 0:
				(out["fired"] as Dictionary)[str(k)] = ((fired as Dictionary)[k] as Dictionary).duplicate(true)
	return out


static func is_empty(rec: Dictionary) -> bool:
	return (rec.get("events", []) as Array).is_empty()


## Add an event; returns its id. One event per instant and action: a second
## "deploy" at the same hour replaces the first (its stamp goes with it).
static func add_event(rec: Dictionary, action: String, at_h: float) -> String:
	if not ACTIONS.has(action) or is_nan(at_h):
		return ""
	for e in rec.get("events", []):
		var ed := e as Dictionary
		if str(ed.get("action", "")) == action and absf(float(ed.get("at_h", 0.0)) - at_h) < 1.0 / 3600.0:
			return str(ed.get("id", ""))
	var id := "ev_%d" % int(rec.get("next_id", 1))
	rec["next_id"] = int(rec.get("next_id", 1)) + 1
	(rec["events"] as Array).append({"id": id, "action": action, "at_h": at_h})
	return id


static func remove_event(rec: Dictionary, id: String) -> bool:
	var evs: Array = rec.get("events", [])
	for i in evs.size():
		if str((evs[i] as Dictionary).get("id", "")) == id:
			evs.remove_at(i)
			(rec.get("fired", {}) as Dictionary).erase(id)
			return true
	return false


## Retime an event. Its stamp is cleared: a moved event is a new promise.
static func move_event(rec: Dictionary, id: String, at_h: float) -> bool:
	if is_nan(at_h):
		return false
	var ev := event(rec, id)
	if ev.is_empty():
		return false
	ev["at_h"] = at_h
	(rec.get("fired", {}) as Dictionary).erase(id)
	return true


static func event(rec: Dictionary, id: String) -> Dictionary:
	for e in rec.get("events", []):
		if str((e as Dictionary).get("id", "")) == id:
			return e
	return {}


## Events by time (ties: deploy before packup, then id).
static func events_sorted(rec: Dictionary) -> Array:
	var out: Array = (rec.get("events", []) as Array).duplicate()
	out.sort_custom(func(a, b) -> bool:
		var ta := float((a as Dictionary).get("at_h", 0.0))
		var tb := float((b as Dictionary).get("at_h", 0.0))
		if absf(ta - tb) > 1e-9:
			return ta < tb
		var aa := str((a as Dictionary).get("action", ""))
		var ab := str((b as Dictionary).get("action", ""))
		if aa != ab:
			return aa == ACTION_DEPLOY
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
	return out


static func is_fired(rec: Dictionary, id: String) -> bool:
	return (rec.get("fired", {}) as Dictionary).has(id)


static func fired_info(rec: Dictionary, id: String) -> Dictionary:
	return (rec.get("fired", {}) as Dictionary).get(id, {})


static func mark_fired(rec: Dictionary, id: String, at_h: float, info: Dictionary = {}) -> void:
	var d := info.duplicate(true)
	d["at"] = at_h
	if not d.has("projects"):
		d["projects"] = []
	if not d.has("items"):
		d["items"] = []
	(rec["fired"] as Dictionary)[id] = d


static func unmark(rec: Dictionary, id: String) -> void:
	(rec.get("fired", {}) as Dictionary).erase(id)


## Events the clock crossed FORWARD between prev_h (exclusive) and now_h
## (inclusive) that have not fired, in time order. A NAN prev_h (the first
## tick after a load) finds nothing: the world already reflects whatever
## fired before the save.
static func due(rec: Dictionary, prev_h: float, now_h: float) -> Array:
	var out: Array = []
	if is_nan(prev_h) or is_nan(now_h) or now_h <= prev_h:
		return out
	for e in events_sorted(rec):
		var ed := e as Dictionary
		var at := float(ed.get("at_h", 0.0))
		if at > prev_h and at <= now_h and not is_fired(rec, str(ed.get("id", ""))):
			out.append(ed)
	return out


## Fired events the clock crossed BACKWARD (now_h < at_h <= prev_h), latest
## first — the order their undo must run in.
static func rewound(rec: Dictionary, prev_h: float, now_h: float) -> Array:
	var out: Array = []
	if is_nan(prev_h) or is_nan(now_h) or now_h >= prev_h:
		return out
	var evs := events_sorted(rec)
	evs.reverse()
	for e in evs:
		var ed := e as Dictionary
		var at := float(ed.get("at_h", 0.0))
		if at > now_h and at <= prev_h and is_fired(rec, str(ed.get("id", ""))):
			out.append(ed)
	return out


## The site as the schedule has it at `t`: the last event at or before `t`
## says whether the site is deployed or packed; `next` is the first event
## after `t` ({} = none). `active` = the last event has fired but its crew is
## not done (the director keeps `pending` / open projects in the stamp).
static func phase_at(rec: Dictionary, t: float) -> Dictionary:
	var last: Dictionary = {}
	var next: Dictionary = {}
	for e in events_sorted(rec):
		var ed := e as Dictionary
		if float(ed.get("at_h", 0.0)) <= t:
			last = ed
		elif next.is_empty():
			next = ed
	var phase := PHASE_NONE
	if not last.is_empty():
		phase = PHASE_DEPLOYED if str(last.get("action", "")) == ACTION_DEPLOY else PHASE_PACKED
	return {"phase": phase, "last": last, "next": next,
		"fired": not last.is_empty() and is_fired(rec, str(last.get("id", "")))}


static func action_label(action: String) -> String:
	return "Deploy the site" if action == ACTION_DEPLOY else "Pack up the site"


static func action_verb(action: String) -> String:
	return "Deploying" if action == ACTION_DEPLOY else "Packing up"


## "Deploy · Tue 14 Oct 09:00" for menus and flags.
static func describe(ev: Dictionary, timecode: Callable = Callable()) -> String:
	var tc := ""
	if timecode.is_valid():
		tc = str(timecode.call(float(ev.get("at_h", 0.0))))
	var name := "Deploy" if str(ev.get("action", "")) == ACTION_DEPLOY else "Pack up"
	return "%s · %s" % [name, tc] if not tc.is_empty() else name
