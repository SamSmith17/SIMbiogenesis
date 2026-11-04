class_name SiteDeploySchedule
extends RefCounted

## The site's DEPLOYMENT SCHEDULE — "set a time on the timeline and everyone
## arrives / builds / packs up / leaves". Pure static helpers over one plain
## record (the FireTimeline idiom: nothing here touches a node, so the
## selftest drives it offline and the director is the only impure half).
##
## Record (saved per world as WorldPaths kind "deploy_schedule"):
##   { version, next_id,
##     events: [ {id, action: "arrive"|"deploy"|"packup"|"leave", at_h} ],
##     fired:  { event_id: {at: abs_h fired, projects: [{iid, pid, item,
##               trace: [[h, frac], …], done_h}], items: [{kind, id}],
##               pending: int, before: {item id: snapshot},
##               after: {item id: snapshot}, done_h} } }
##
## Two kinds of event:
##   - CREW events (deploy / packup) FIRE once when the clock crosses `at_h`
##     FORWARD (`due`); the crew then does the work through Site Projects.
##     Scrubbing BACK past a fired event (`rewound`) undoes it: the crew's
##     work cannot be reversed, so the world is put back as it was before
##     the event (the `before` snapshot) and the stamp cleared, which makes
##     the next forward crossing fire it again. Inside a FINISHED event's
##     window [at_h, done_h] the director REPLAYS the build from the
##     projects' progress traces, so the clock scrubs through it.
##   - DRIVE events (arrive / leave) never fire: they are DECLARATIVE. The
##     director writes the vehicles' arrival / departure records from them
##     the moment they are added, moved or removed, and VehicleDrive is a pure
##     function of the clock, so they scrub by construction. People with no
##     vehicle follow `people_present`.
##   - moving an event clears its stamp for the same reason.

const VERSION := 1
const ACTION_DEPLOY := "deploy"
const ACTION_PACKUP := "packup"
const ACTION_ARRIVE := "arrive"
const ACTION_LEAVE := "leave"
const ACTIONS := [ACTION_ARRIVE, ACTION_DEPLOY, ACTION_PACKUP, ACTION_LEAVE]
## The events a crew works (they fire); the others drive the vehicles.
const CREW_ACTIONS := [ACTION_DEPLOY, ACTION_PACKUP]
const DRIVE_ACTIONS := [ACTION_ARRIVE, ACTION_LEAVE]
## Ties at one hour run in this order (people arrive before they build …).
const ORDER := {ACTION_ARRIVE: 0, ACTION_DEPLOY: 1, ACTION_PACKUP: 2, ACTION_LEAVE: 3}

## Site phase names (phase_at): the site as the LAST crew event left it.
const PHASE_NONE := "unscheduled"
const PHASE_DEPLOYED := "deployed"
const PHASE_PACKED := "packed"

## The record keys a snapshot of a prop's transport state carries (`before` /
## `after`): where it stands, how it is packed, where it is stowed, where it
## belongs. Restoring them is an exact undo of a crew's work on it.
const SNAPSHOT_KEYS := ["x", "z", "yaw", "y_offset", "ground_y", "packed", "stowed_in",
	"stow_local", "unload_rank", "deploy_home", "collision_enabled", "linkage_deployed",
	"linkage_fold_deg"]


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


static func is_crew_action(action: String) -> bool:
	return CREW_ACTIONS.has(action)


static func is_drive_action(action: String) -> bool:
	return DRIVE_ACTIONS.has(action)


## Add an event; returns its id. One event per instant and action: a second
## "deploy" at the same hour replaces the first (its stamp goes with it).
## The vehicles carry ONE arrival and ONE departure, so a second ARRIVE (or
## LEAVE) anywhere on the timeline RETIMES the existing one.
static func add_event(rec: Dictionary, action: String, at_h: float) -> String:
	if not ACTIONS.has(action) or is_nan(at_h):
		return ""
	for e in rec.get("events", []):
		var ed := e as Dictionary
		if str(ed.get("action", "")) != action:
			continue
		if is_drive_action(action):
			ed["at_h"] = at_h
			return str(ed.get("id", ""))
		if absf(float(ed.get("at_h", 0.0)) - at_h) < 1.0 / 3600.0:
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


## The one event of a drive action ({} when none).
static func event_of(rec: Dictionary, action: String) -> Dictionary:
	for e in rec.get("events", []):
		if str((e as Dictionary).get("action", "")) == action:
			return e
	return {}


## Events by time (ties: arrive, deploy, packup, leave, then id).
static func events_sorted(rec: Dictionary) -> Array:
	var out: Array = (rec.get("events", []) as Array).duplicate()
	out.sort_custom(func(a, b) -> bool:
		var ta := float((a as Dictionary).get("at_h", 0.0))
		var tb := float((b as Dictionary).get("at_h", 0.0))
		if absf(ta - tb) > 1e-9:
			return ta < tb
		var aa := int(ORDER.get(str((a as Dictionary).get("action", "")), 9))
		var ab := int(ORDER.get(str((b as Dictionary).get("action", "")), 9))
		if aa != ab:
			return aa < ab
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
	return out


## The crew events only, by time.
static func crew_events(rec: Dictionary) -> Array:
	var out: Array = []
	for e in events_sorted(rec):
		if is_crew_action(str((e as Dictionary).get("action", ""))):
			out.append(e)
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


## Crew events the clock crossed FORWARD between prev_h (exclusive) and
## now_h (inclusive) that have not fired, in time order. A NAN prev_h (the
## first tick after a load) finds nothing: the world already reflects
## whatever fired before the save. Drive events never fire.
static func due(rec: Dictionary, prev_h: float, now_h: float) -> Array:
	var out: Array = []
	if is_nan(prev_h) or is_nan(now_h) or now_h <= prev_h:
		return out
	for e in crew_events(rec):
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
	var evs := crew_events(rec)
	evs.reverse()
	for e in evs:
		var ed := e as Dictionary
		var at := float(ed.get("at_h", 0.0))
		if at > now_h and at <= prev_h and is_fired(rec, str(ed.get("id", ""))):
			out.append(ed)
	return out


## The site as the schedule has it at `t`: the last CREW event at or before
## `t` says whether the site is deployed or packed; `next` is the first crew
## event after `t` ({} = none). `fired` = the last event has fired.
static func phase_at(rec: Dictionary, t: float) -> Dictionary:
	var last: Dictionary = {}
	var next: Dictionary = {}
	for e in crew_events(rec):
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


## Whether the site's PEOPLE are here at `t` by the drive events alone: with
## no ARRIVE event everyone has always been here; an ARRIVE puts them away
## before it; a LEAVE puts them away from it on. (A camp whose vehicles are
## scheduled follows its vehicles instead — the bridge decides which.)
static func people_present(rec: Dictionary, t: float) -> bool:
	var present := event_of(rec, ACTION_ARRIVE).is_empty()
	for e in events_sorted(rec):
		var ed := e as Dictionary
		var action := str(ed.get("action", ""))
		if not is_drive_action(action) or float(ed.get("at_h", 0.0)) > t:
			continue
		present = action == ACTION_ARRIVE
	return present


## The next hour from `t` the people are here again (INF = never by the
## schedule): the ARRIVE event ahead of `t`.
static func next_present_h(rec: Dictionary, t: float) -> float:
	var ev := event_of(rec, ACTION_ARRIVE)
	if ev.is_empty():
		return INF
	var at := float(ev.get("at_h", 0.0))
	return at if at > t else INF


## A project's progress at `t` read off its trace ([[h, frac], …], h
## ascending): held at the first sample before it, interpolated between
## samples, the last value after. An empty trace is 0.
static func trace_frac(trace: Array, t: float) -> float:
	if trace.is_empty():
		return 0.0
	var first: Array = trace[0]
	if t <= float(first[0]):
		return clampf(float(first[1]), 0.0, 1.0)
	for i in range(1, trace.size()):
		var a: Array = trace[i - 1]
		var b: Array = trace[i]
		if t <= float(b[0]):
			var span := maxf(float(b[0]) - float(a[0]), 1e-9)
			var u := clampf((t - float(a[0])) / span, 0.0, 1.0)
			return clampf(lerpf(float(a[1]), float(b[1]), u), 0.0, 1.0)
	var last: Array = trace[trace.size() - 1]
	return clampf(float(last[1]), 0.0, 1.0)


## Append a sample to a trace when it is worth keeping: a new frac that
## moved by `min_step`, or the first / final value. Monotone in time (a
## sample older than the last is dropped).
static func trace_push(trace: Array, t: float, frac: float, min_step: float = 0.02) -> bool:
	var f := clampf(frac, 0.0, 1.0)
	if trace.is_empty():
		trace.append([t, f])
		return true
	var last: Array = trace[trace.size() - 1]
	if t < float(last[0]):
		return false
	if absf(f - float(last[1])) < min_step and not (f >= 1.0 and float(last[1]) < 1.0):
		return false
	trace.append([t, f])
	return true


## The transport snapshot of a prop record (SNAPSHOT_KEYS present on it).
static func snapshot(rec: Dictionary) -> Dictionary:
	var out := {}
	for k in SNAPSHOT_KEYS:
		if rec.has(k):
			out[k] = rec[k]
	return out


## The patch that puts a record back to `snap`: every snapshot key, a key the
## snapshot lacks erased (null — PlacedPropLayer.update_prop treats null as
## an erase).
static func restore_patch(snap: Dictionary) -> Dictionary:
	var out := {}
	for k in SNAPSHOT_KEYS:
		out[k] = snap.get(k, null)
	return out


static func action_label(action: String) -> String:
	match action:
		ACTION_DEPLOY:
			return "Deploy the site"
		ACTION_PACKUP:
			return "Pack up the site"
		ACTION_ARRIVE:
			return "Everyone arrives"
		ACTION_LEAVE:
			return "Everyone leaves"
	return action


static func action_verb(action: String) -> String:
	match action:
		ACTION_DEPLOY:
			return "Deploying"
		ACTION_PACKUP:
			return "Packing up"
		ACTION_ARRIVE:
			return "Arriving"
		ACTION_LEAVE:
			return "Leaving"
	return action


## The short name on a flag / menu row.
static func action_name(action: String) -> String:
	match action:
		ACTION_DEPLOY:
			return "Deploy"
		ACTION_PACKUP:
			return "Pack up"
		ACTION_ARRIVE:
			return "Arrive"
		ACTION_LEAVE:
			return "Leave"
	return action


## "Deploy · Tue 14 Oct 09:00" for menus and flags.
static func describe(ev: Dictionary, timecode: Callable = Callable()) -> String:
	var tc := ""
	if timecode.is_valid():
		tc = str(timecode.call(float(ev.get("at_h", 0.0))))
	var name := action_name(str(ev.get("action", "")))
	return "%s · %s" % [name, tc] if not tc.is_empty() else name
