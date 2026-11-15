class_name ScheduledEvents
extends RefCounted

## Everything that is scheduled to happen on the site, as ONE list the timeline,
## the Community schedule window and the calendar export all read. Pure: every
## source is handed in as plain data (ScheduleSources does the gathering), so
## the selftest feeds it fixtures.
##
##   event = {id, kind, at_h, end_h, label, source, ref, editable, who: [ids]}
##
## `at_h` / `end_h` are absolute sim hours on the site's clock (end_h == at_h
## for an instant). `source` says which system owns the event and therefore
## who a retime is routed to: "deploy" (SiteDeploySchedule), "burn" (a prop's
## burn record), "set" (a venue programme slot), "vehicle" (a scheduled drive,
## follows the deploy events), "meal" (the routine's EAT blocks), "rota"
## (NpcWorkScheduler shifts). `editable` is true for the ones a drag may move.

const KIND_DEPLOY := "deploy"
const KIND_PACKUP := "packup"
const KIND_ARRIVE := "arrive"
const KIND_LEAVE := "leave"
const KIND_BURN := "burn"
const KIND_SET := "set"
const KIND_VEHICLE_IN := "vehicle_in"
const KIND_VEHICLE_OUT := "vehicle_out"
const KIND_MEAL := "meal"
const KIND_SHIFT := "shift"

const SOURCE_DEPLOY := "deploy"
const SOURCE_BURN := "burn"
const SOURCE_SET := "set"
const SOURCE_VEHICLE := "vehicle"
const SOURCE_MEAL := "meal"
const SOURCE_ROTA := "rota"

const KINDS: Array = [KIND_DEPLOY, KIND_PACKUP, KIND_ARRIVE, KIND_LEAVE, KIND_BURN,
	KIND_SET, KIND_VEHICLE_IN, KIND_VEHICLE_OUT, KIND_MEAL, KIND_SHIFT]

## What the kinds are called to a player (one word for a chip, a phrase for a row).
const KIND_WORDS: Dictionary = {
	KIND_DEPLOY: "Deploy", KIND_PACKUP: "Pack up", KIND_ARRIVE: "Arrive",
	KIND_LEAVE: "Leave", KIND_BURN: "Burn", KIND_SET: "Set",
	KIND_VEHICLE_IN: "Vehicle in", KIND_VEHICLE_OUT: "Vehicle out",
	KIND_MEAL: "Meal", KIND_SHIFT: "Shift",
}

## One colour per kind, on the dark surfaces. The timeline flags keep their own
## (FLAG_*_COL); these are close to them so the two read as one.
const KIND_COLORS: Dictionary = {
	KIND_DEPLOY: Color(0.36, 0.80, 0.46), KIND_PACKUP: Color(0.93, 0.62, 0.30),
	KIND_ARRIVE: Color(0.30, 0.78, 0.76), KIND_LEAVE: Color(0.62, 0.64, 0.70),
	KIND_BURN: Color(1.0, 0.45, 0.15), KIND_SET: Color(0.74, 0.50, 0.95),
	KIND_VEHICLE_IN: Color(0.42, 0.70, 0.95), KIND_VEHICLE_OUT: Color(0.55, 0.60, 0.80),
	KIND_MEAL: Color(0.95, 0.80, 0.36), KIND_SHIFT: Color(0.45, 0.66, 0.98),
}

## The timeline's flag kinds (instants it already draws and drags).
const FLAG_KINDS: Array = [KIND_DEPLOY, KIND_PACKUP, KIND_ARRIVE, KIND_LEAVE, KIND_BURN]


static func make(id: String, kind: String, at_h: float, end_h: float, label: String,
		source: String, ref: Variant = "", editable: bool = false, who: Array = []) -> Dictionary:
	return {"id": id, "kind": kind, "at_h": at_h, "end_h": maxf(end_h, at_h), "label": label,
		"source": source, "ref": ref, "editable": editable, "who": who.duplicate()}


static func is_span(ev: Dictionary) -> bool:
	return float(ev.get("end_h", 0.0)) > float(ev.get("at_h", 0.0)) + 1e-6


static func duration_h(ev: Dictionary) -> float:
	return maxf(float(ev.get("end_h", 0.0)) - float(ev.get("at_h", 0.0)), 0.0)


static func color_of(kind: String) -> Color:
	return KIND_COLORS.get(kind, Color(0.7, 0.72, 0.78))


static func word_of(kind: String) -> String:
	return str(KIND_WORDS.get(kind, kind.capitalize()))


static func day_of(abs_h: float) -> int:
	return int(floor(abs_h / 24.0))


## Does [a, b] overlap the window [h0, h1]? An instant counts on its hour.
static func overlaps(ev: Dictionary, h0: float, h1: float) -> bool:
	var a := float(ev.get("at_h", 0.0))
	var b := float(ev.get("end_h", a))
	if b <= a:
		return a >= h0 and a <= h1
	return b > h0 and a < h1


static func in_window(evs: Array, h0: float, h1: float) -> Array:
	var out: Array = []
	for e in evs:
		if overlaps(e as Dictionary, h0, h1):
			out.append(e)
	return out


## Sorted by start, then kind order, then id (stable for the UI and the export).
static func sort(evs: Array) -> Array:
	var out := evs.duplicate()
	out.sort_custom(func(a, b) -> bool:
		var ta := float((a as Dictionary).get("at_h", 0.0))
		var tb := float((b as Dictionary).get("at_h", 0.0))
		if absf(ta - tb) > 1e-6:
			return ta < tb
		var ka := KINDS.find(str((a as Dictionary).get("kind", "")))
		var kb := KINDS.find(str((b as Dictionary).get("kind", "")))
		if ka != kb:
			return ka < kb
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
	return out


static func find(evs: Array, id: String) -> Dictionary:
	for e in evs:
		if str((e as Dictionary).get("id", "")) == id:
			return e
	return {}


## Events for one person: everything with nobody named (site-wide) plus what
## names them.
static func for_person(evs: Array, agent_id: String) -> Array:
	var out: Array = []
	for e in evs:
		var who: Array = (e as Dictionary).get("who", [])
		if who.is_empty() or who.has(agent_id):
			out.append(e)
	return out


# --- sources ------------------------------------------------------------------

## SiteDeploySchedule events [{id, action, at_h}].
static func from_deploy(events: Array) -> Array:
	var out: Array = []
	for e in events:
		var ev: Dictionary = e
		var action := str(ev.get("action", ""))
		var kind := action if KINDS.has(action) else KIND_DEPLOY
		var t := float(ev.get("at_h", 0.0))
		out.append(make(str(ev.get("id", "")), kind, t, t, word_of(kind), SOURCE_DEPLOY,
			str(ev.get("id", "")), true))
	return out


## The loader's scheduled burns [{id "burn:<prop>", prop_id, at_h, label}].
static func from_burns(burns: Array) -> Array:
	var out: Array = []
	for b in burns:
		var bd: Dictionary = b
		var t := float(bd.get("at_h", 0.0))
		out.append(make(str(bd.get("id", "")), KIND_BURN, t, t,
			"Burn: %s" % str(bd.get("label", "structure")), SOURCE_BURN,
			str(bd.get("prop_id", "")), true))
	return out


## Venue programmes: every slot of every programmed space, once a day across
## [h0, h1]. A slot with `day` >= 0 still repeats daily, as FestivalProgram
## reads it (it is never asked with a day). The id is stable per space, slot
## and day, so the export updates a set rather than duplicating it.
static func from_programs(spaces: Array, h0: float, h1: float) -> Array:
	var out: Array = []
	var d0 := day_of(h0) - 1
	var d1 := day_of(h1)
	for s in spaces:
		var sp: Dictionary = s
		var slots: Array = sp.get("program", [])
		if slots.is_empty():
			continue
		var sid := str(sp.get("id", ""))
		var venue := str(sp.get("label", "")).strip_edges()
		if venue.is_empty():
			venue = str(sp.get("type", "venue")).capitalize()
		for k in slots.size():
			var slot: Dictionary = slots[k]
			var a := fposmod(float(slot.get("start_h", 20.0)), 24.0)
			var len_h := fposmod(float(slot.get("end_h", 23.0)) - a, 24.0)
			if len_h <= 1e-6:
				len_h = 24.0
			var name := str(slot.get("label", "")).strip_edges()
			var label := venue if name.is_empty() else "%s — %s" % [venue, name]
			for day in range(d0, d1 + 1):
				var st := float(day) * 24.0 + a
				var ev := make("set:%s:%d:%d" % [sid, k, day], KIND_SET, st, st + len_h, label,
					SOURCE_SET, {"space_id": sid, "slot": k, "day": day}, true)
				if overlaps(ev, h0, h1):
					out.append(ev)
	return out


## Scheduled drives (TerrainLoader.vehicle_arrivals): the drive in from its
## start to parking, and the drive out from leaving to gone. `names`: {id: label}.
static func from_vehicles(arrivals: Array, names: Dictionary = {}) -> Array:
	var out: Array = []
	for v in arrivals:
		var vd: Dictionary = v
		var vid := str(vd.get("id", ""))
		var name := str(names.get(vid, "Vehicle"))
		var st := float(vd.get("start_h", NAN))
		var park := float(vd.get("park_h", -INF))
		if not is_nan(st) and is_finite(park):
			out.append(make("vin:%s" % vid, KIND_VEHICLE_IN, st, maxf(park, st), "%s drives in" % name,
				SOURCE_VEHICLE, vid))
		var leave := float(vd.get("leave_h", INF))
		if is_finite(leave):
			var gone := float(vd.get("gone_h", leave))
			out.append(make("vout:%s" % vid, KIND_VEHICLE_OUT, leave,
				gone if is_finite(gone) else leave, "%s drives out" % name, SOURCE_VEHICLE, vid))
	return out


## The routine's EAT blocks as community meals, once a day across [h0, h1]
## (the shared schedule, not anyone's personal shift of it). `tag` keeps two
## habitats' meals apart.
static func from_meals(blocks: Array, h0: float, h1: float, tag: String = "",
		place: String = "") -> Array:
	var out: Array = []
	var d0 := day_of(h0) - 1
	var d1 := day_of(h1)
	var k := 0
	for b in blocks:
		var bd: Dictionary = b
		if str(bd.get("kind", "")) != NpcRoutine.EAT:
			continue
		var a := fposmod(float(bd.get("start_h", 0.0)), 24.0)
		var len_h := fposmod(float(bd.get("end_h", 0.0)) - a, 24.0)
		if len_h <= 1e-6:
			k += 1
			continue
		var label := meal_name(a)
		if not place.is_empty():
			label = "%s — %s" % [label, place]
		for day in range(d0, d1 + 1):
			var st := float(day) * 24.0 + a
			var ev := make("meal:%s:%d:%d" % [tag, k, day], KIND_MEAL, st, st + len_h, label,
				SOURCE_MEAL, {"habitat": tag, "block": k, "day": day})
			if overlaps(ev, h0, h1):
				out.append(ev)
		k += 1
	return out


static func meal_name(hour: float) -> String:
	if hour < 10.5:
		return "Breakfast"
	if hour < 15.5:
		return "Lunch"
	return "Dinner"


## NpcWorkScheduler shifts {key: {agents, start_h, end_h, day, hours, label,
## family, kind, ref}} as spans naming their crew. `names`: {agent id: name}.
static func from_rota(rota: Dictionary, names: Dictionary = {}, tag: String = "") -> Array:
	var out: Array = []
	var shifts: Dictionary = rota.get("shifts", {})
	for key in shifts:
		var sh: Dictionary = shifts[key]
		var st := float(int(sh.get("day", 0))) * 24.0 + float(sh.get("start_h", 0.0))
		var hrs := float(sh.get("hours", 0.0))
		var crew: Array = sh.get("agents", [])
		var who_names: Array = []
		for a in crew:
			who_names.append(str(names.get(str(a), str(a))))
		var label := str(sh.get("label", "Work"))
		if not who_names.is_empty():
			label = "%s — %s" % [label, ", ".join(who_names)]
		out.append(make("rota:%s:%s" % [tag, str(key)], KIND_SHIFT, st, st + hrs, label,
			SOURCE_ROTA, {"habitat": tag, "key": str(key), "family": str(sh.get("family", "")),
				"chore": str(sh.get("label", ""))}, false, crew))
	return out


## Merge any number of source lists into one sorted list, dropping duplicate ids.
static func merge(lists: Array) -> Array:
	var seen := {}
	var all: Array = []
	for l in lists:
		for e in l:
			var id := str((e as Dictionary).get("id", ""))
			if seen.has(id):
				continue
			seen[id] = true
			all.append(e)
	return sort(all)


# --- a person's day -------------------------------------------------------------

## What one person's day looks like: [{a, b, kind, label}] in absolute hours
## over the calendar day `day` (midnight to midnight), from their own routine
## day (NpcRoutine.block_at with their key, so their chronotype's moved night
## and the daily jitter are in it) with their rota shifts laid over it.
## Sampled every `step_h` and merged into runs: the same answer the agent gets
## when it asks the routine what to do at that hour.
static func person_day(routine: NpcRoutine, agent_id: String, offset_h: float, day: int,
		shifts: Array = [], step_h: float = 0.25) -> Array:
	var out: Array = []
	if routine == null:
		return out
	var t0 := float(day) * 24.0
	var n := int(round(24.0 / step_h))
	var cur := ""
	var a := t0
	for i in n:
		var t := t0 + float(i) * step_h
		var key := routine.day_key(agent_id, t + step_h * 0.5, offset_h)
		var blk := routine.block_at(fposmod(t + step_h * 0.5, 24.0), offset_h, key)
		var kind := str(blk.get("kind", NpcRoutine.FREE))
		if kind != cur:
			if not cur.is_empty():
				out.append({"a": a, "b": t, "kind": cur, "label": str(NpcRoutine.LABELS.get(cur, cur))})
			cur = kind
			a = t
	if not cur.is_empty():
		out.append({"a": a, "b": t0 + 24.0, "kind": cur, "label": str(NpcRoutine.LABELS.get(cur, cur))})
	# Shifts over the top (they are what the person will be doing then).
	for s in shifts:
		var ev: Dictionary = s
		var sa := maxf(float(ev.get("at_h", 0.0)), t0)
		var sb := minf(float(ev.get("end_h", 0.0)), t0 + 24.0)
		if sb <= sa:
			continue
		out = _overlay(out, {"a": sa, "b": sb, "kind": KIND_SHIFT,
			"label": str((ev.get("ref", {}) as Dictionary).get("chore", ev.get("label", "Work")))
				if ev.get("ref", null) is Dictionary else str(ev.get("label", "Work"))})
	return out


static func _overlay(segs: Array, top: Dictionary) -> Array:
	var out: Array = []
	var ta := float(top["a"])
	var tb := float(top["b"])
	var placed := false
	for s in segs:
		var sd: Dictionary = s
		var a := float(sd["a"])
		var b := float(sd["b"])
		if b <= ta or a >= tb:
			if a >= tb and not placed:
				out.append(top)
				placed = true
			out.append(sd)
			continue
		if a < ta:
			var left := sd.duplicate()
			left["b"] = ta
			out.append(left)
		if not placed:
			out.append(top)
			placed = true
		if b > tb:
			var right := sd.duplicate()
			right["a"] = tb
			out.append(right)
	if not placed:
		out.append(top)
	return out


## Hours by kind in a person_day result.
static func hours_by_kind(segs: Array) -> Dictionary:
	var out := {}
	for s in segs:
		var sd: Dictionary = s
		var k := str(sd.get("kind", ""))
		out[k] = float(out.get(k, 0.0)) + float(sd.get("b", 0.0)) - float(sd.get("a", 0.0))
	return out
