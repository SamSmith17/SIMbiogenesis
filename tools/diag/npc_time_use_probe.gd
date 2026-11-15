extends SceneTree

## How do simulated people spend their days? (NPC life pass, Phase 0.) Runs a
## camp through BOTH tiers on a synthetic site for a week and tallies, per
## person, the hours in each time-use category (sleep, toilet, washing,
## eating, drinking, work by family, walking, queueing, social, venues, idle),
## toilet visits per day, how many visits used a chair pose with no seat
## under the person, how the work hours spread across the camp (min / max /
## Gini) and whether anybody worked inside their own sleep window.
##
## The work on the board is a plain site load (meals, toilets, water, garden,
## maintenance): `--work=<person-hours a day>` scales it. The light tier has
## no board (it banks work statistically), so the fairness lines are full tier.
## Offline, deterministic; --import first.
##   godot --headless --path . --script tools/diag/npc_time_use_probe.gd [-- --days=7 --n=24 --routine=default|festival --work=20]

const STEP_H := 1.0 / 30.0
const START_H := 8.0
const WARMUP_H := 14.0


## Plan the weekly rota each day (NpcWorkScheduler), as the bridge does.
var _rota := true
var _who := false
var _trace := ""
var _rota_kept := 0.0
var _rota_total := 0.0


func _init() -> void:
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.reset_custom_names_for_test()
	var days := 7.0
	var n := 24
	var routine := "default"
	var work := 20.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--days="):
			days = float(a.substr(7))
		elif a.begins_with("--n="):
			n = int(a.substr(4))
		elif a.begins_with("--routine="):
			routine = a.substr(10)
		elif a.begins_with("--work="):
			work = float(a.substr(7))
		elif a.begins_with("--trace="):
			_trace = a.substr(8)
		elif a == "--who":
			_who = true
		elif a.begins_with("--rota="):
			_rota = a.substr(7) != "0"
	print("NPC TIME-USE PROBE  n=%d days=%.1f routine=%s work=%.0f person-h/day rota=%s" % [n, days, routine, work, _rota])
	_probe_full(n, days, routine, work)
	_probe_light(n, days, routine)
	quit(0)


# --- site ----------------------------------------------------------------------

func _square(c: Vector2, half: float) -> Array:
	return [[c.x - half, c.y - half], [c.x + half, c.y - half], [c.x + half, c.y + half], [c.x - half, c.y + half]]


func _site() -> SpaceRegistry:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(60, 0), 8)}, "kitchen", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-60, 30), 8)}, "restroom", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-60, -30), 8)}, "restroom", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, 70), 8)}, "water_point", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, -80), 12)}, "sleep", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-45, -45), 8)}, "shower", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(55, 55), 8)}, "fire_circle", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-70, -60), 10)}, "center_camp", 0)
	reg.refresh_positions(func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null))
	return reg


func _routine_for(kind: String) -> NpcRoutine:
	return NpcRoutine.festival_day() if kind == "festival" else NpcRoutine.default_day()


## A plain site's daily work, scaled to `per_day` person-hours.
## [label, person-hours, min crew, max crew, window start, end, x, z]
const WORK := [
	["Cook breakfast", 2.0, 1, 2, 6.5, 8.0, 60.0, 0.0],
	["Cook lunch", 3.0, 2, 3, 11.0, 13.0, 60.0, 0.0],
	["Cook dinner", 4.0, 2, 3, 16.0, 18.0, 60.0, 0.0],
	["Wash up", 2.0, 1, 2, 18.5, 20.0, 60.0, 0.0],
	["Clean the toilets", 1.5, 1, 1, 9.0, 17.0, -60.0, 30.0],
	["Water run", 1.5, 1, 2, 8.0, 18.0, 0.0, 70.0],
	["Tend the garden", 3.0, 1, 3, 7.0, 12.0, 30.0, -30.0],
	["Maintenance", 3.0, 1, 2, 9.0, 18.0, -20.0, 20.0],
]


func _seed_board(per_day: float) -> NpcChoreBoard:
	var board := NpcChoreBoard.create_empty()
	var total := 0.0
	for w: Array in WORK:
		total += float(w[1])
	var k := per_day / maxf(total, 0.01)
	for w: Array in WORK:
		board.add_chore(str(w[0]), float(w[1]) * k, {
			"window": {"start_h": float(w[4]), "end_h": float(w[5])},
			"repeat": "daily", "min_workers": int(w[2]), "max_workers": int(w[3]),
			"exposure": NpcWeatherGate.EXPOSURE_SHELTERED,
			"target": {"kind": "pos", "x": float(w[6]), "z": float(w[7])},
		})
	return board


# --- tallies -------------------------------------------------------------------

const CATS := ["sleep", "toilet", "wash", "eat", "drink", "work", "walk", "queue",
	"social", "venue", "idle"]


class Person:
	var hours: Dictionary = {}
	var work_by: Dictionary = {}
	var toilet_visits := 0
	var poo_visits := 0
	var chair_no_seat := 0
	var work_in_sleep_h := 0.0
	var was_toilet := false
	var label := ""
	var was_asleep := false
	var asleep_since := 0.0
	var wakes: Array = []
	var beds: Array = []

	func add(cat: String, h: float) -> void:
		hours[cat] = float(hours.get(cat, 0.0)) + h

	## Bed and wake times of the main night (a sleep of 3 h or more).
	func track_sleep(asleep: bool, t: float) -> void:
		if asleep and not was_asleep:
			asleep_since = t
		elif not asleep and was_asleep and t - asleep_since >= 3.0:
			var b := fposmod(asleep_since, 24.0)
			beds.append(b + 24.0 if b < 12.0 else b)
			wakes.append(fposmod(t, 24.0))
		was_asleep = asleep


func _cat_full(a: NpcAgent) -> String:
	return NpcTimeUse.category_full(a.state, a.activity)


func _cat_light(c: CrowdCohort, i: int) -> String:
	return NpcTimeUse.category_light(int(c.state[i]), int(c.act[i]))


var _hour_starts: Dictionary = {}


func _visit_started(t: float) -> void:
	var h := int(floor(fposmod(t, 24.0)))
	_hour_starts[h] = int(_hour_starts.get(h, 0)) + 1


func _report(title: String, people: Dictionary, days: float) -> void:
	print("--- %s: %d people, %.1f days measured ---" % [title, people.size(), days])
	var line := "  hours/person/day  "
	for cat: String in CATS:
		var s := 0.0
		for p: Person in people.values():
			s += float(p.hours.get(cat, 0.0))
		line += "%s %.2f  " % [cat, s / maxf(people.size() * days, 1e-6)]
	print(line)
	var visits: Array = []
	var chair := 0
	var sleepwork := 0.0
	for p: Person in people.values():
		visits.append(p.toilet_visits / maxf(days, 1e-6))
		chair += p.chair_no_seat
		sleepwork += p.work_in_sleep_h
	visits.sort()
	if not visits.is_empty():
		print("  toilet visits/person/day  min %.2f  median %.2f  max %.2f" % [visits[0], visits[visits.size() / 2], visits[-1]])
	var poos := 0
	for p: Person in people.values():
		poos += p.poo_visits
	print("  of which poos/person/day %.2f (pees %.2f)" % [poos / maxf(people.size() * days, 1e-6),
		(float(visits.reduce(func(a, b): return a + b, 0.0)) / maxf(visits.size(), 1)) - poos / maxf(people.size() * days, 1e-6)])
	var waking := 0
	var peak := 0
	var total := 0
	for h in range(7, 23):
		var c := int(_hour_starts.get(h, 0))
		total += c
		peak = maxi(peak, c)
		waking += 1
	if total > 0:
		print("  toilet starts by hour (07-23): peak / mean %.2f" % (float(peak) / (float(total) / waking)))
	_hour_starts = {}
	_report_chronotypes(people)
	print("  toilet visits in a chair pose with no seat: %d" % chair)
	print("  work hours inside the person's sleep window: %.2f" % sleepwork)
	var wh: Array = []
	for p: Person in people.values():
		wh.append(float(p.hours.get("work", 0.0)) / maxf(days, 1e-6) * 7.0)
	wh.sort()
	if not wh.is_empty():
		var mean := 0.0
		for v: float in wh:
			mean += v
		mean /= wh.size()
		print("  work h/person/week  min %.1f  mean %.1f  max %.1f  Gini %.3f" % [wh[0], mean, wh[-1], _gini(wh)])


func _report_chronotypes(people: Dictionary) -> void:
	var line := "  bed / wake by chronotype:"
	for lab in ["Early bird", "In between", "Night owl"]:
		var bed := 0.0
		var wake := 0.0
		var nb := 0
		var nw := 0
		var who := 0
		for p: Person in people.values():
			if p.label != lab:
				continue
			who += 1
			for b: float in p.beds:
				bed += b
				nb += 1
			for w: float in p.wakes:
				wake += w
				nw += 1
		if nb == 0 or nw == 0:
			continue
		line += "  %s (%d) %s / %s" % [lab, who, _hhmm(fposmod(bed / nb, 24.0)), _hhmm(wake / nw)]
	print(line)


static func _hhmm(h: float) -> String:
	return "%02d:%02d" % [int(h), int(fposmod(h * 60.0, 60.0))]


static func _gini(sorted_vals: Array) -> float:
	var n := sorted_vals.size()
	if n == 0:
		return 0.0
	var s := 0.0
	var w := 0.0
	for i in n:
		s += float(sorted_vals[i])
		w += float(i + 1) * float(sorted_vals[i])
	if s <= 0.0:
		return 0.0
	return (2.0 * w) / (n * s) - float(n + 1) / n


# --- tiers ---------------------------------------------------------------------

func _probe_full(n: int, days: float, routine: String, work: float) -> void:
	var reg := _site()
	var e := NpcPopulationEngine.new()
	e.configure(n, "tu", Vector2.ZERO)
	e.routine = _routine_for(routine)
	e.chore_board = _seed_board(work)
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var chore_pos := func(chore: Dictionary) -> Variant:
		var t: Dictionary = chore.get("target", {})
		if str(t.get("kind", "")) == "pos":
			return Vector2(float(t.get("x", 0.0)), float(t.get("z", 0.0)))
		return null
	var ctx := func(tt: float) -> Dictionary:
		return {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(tt, 24.0),
			"abs_hours": tt, "camp_home": Vector2.ZERO, "camp_seed": "tu",
			"routine": e.routine, "chore_pos_of": chore_pos}
	var people: Dictionary = {}
	var t := START_H
	e.tick(t, ctx.call(t))
	var end := START_H + days * 24.0
	while t < end - 1e-9:
		t += STEP_H
		if _rota:
			e.plan_rota(t)
		e.tick(t, ctx.call(t))
		if t < WARMUP_H:
			continue
		for a: NpcAgent in e.agents:
			var p: Person = people.get(a.id, null)
			if p == null:
				p = Person.new()
				people[a.id] = p
			var cat := _cat_full(a)
			p.add(cat, STEP_H)
			if a.id == _trace and int(round(t * 4.0)) % 1 == 0 and fposmod(t, 1.0) < STEP_H + 1e-6:
				var mine := []
				for c in e.chore_board.chores:
					var cd: Dictionary = c
					if cd.has("rota_day") and (cd.get("assigned_crew", []) as Array).has(a.id):
						mine.append("%s@%.2f%s" % [str(cd["label"]).substr(0, 8), fposmod(float(cd.get("assign_at_h", 0.0)), 24.0),
							" DONE" if int(cd.get("done_day", -1)) >= NpcChoreBoard.day_index(t) else ""])
				var b := e.routine.block_at(fposmod(t, 24.0), a.routine_offset_h, e.routine.day_key(a.id, t, a.routine_offset_h))
				print("TRACE %.2f %s st %d act %s chore %s needs h%.2f t%.2f b%.2f s%.2f y%.2f  mine %s" % [fposmod(t, 24.0), str(b.get("kind")), a.state, a.activity, a.chore_id,
					a.needs["hunger"], a.needs["thirst"], a.needs["bladder"], a.needs["sleep"], a.needs["hygiene"], mine])
			if p.label == "":
				p.label = NpcPersona.chronotype_label(e.routine.persona_of(a.id))
			p.track_sleep(cat == "sleep", t)
			var in_toilet := cat == "toilet"
			if in_toilet and not p.was_toilet:
				p.toilet_visits += 1
				_visit_started(t)
				if a.poop_now:
					p.poo_visits += 1
				# A chair pose with no seat under it (NpcSeatPose decides the
				# pose: only a toilet seat >= 0.3 m takes the chair).
				if NpcSeatPose.for_activity("bladder", "", a.seat_kind, a.seat_elev, a.id) == NpcSeatPose.CHAIR \
						and a.seat_elev < 0.3:
					p.chair_no_seat += 1
			p.was_toilet = in_toilet
			if cat == "work" and not a.chore_id.is_empty():
				var ch := e.chore_board.find(a.chore_id)
				if ch.has("rota_day"):
					_rota_total += STEP_H
					if (ch.get("assigned_crew", []) as Array).has(a.id):
						_rota_kept += STEP_H
			if cat == "work" and e.routine != null:
				var b: Dictionary = e.routine.block_at(fposmod(t, 24.0), a.routine_offset_h,
					e.routine.day_key(a.id, t, a.routine_offset_h))
				if str(b.get("kind", "")) == NpcRoutine.SLEEP:
					p.work_in_sleep_h += STEP_H
	_report("FULL tier", people, days - (WARMUP_H - START_H) / 24.0)
	if _rota and not e.rota.is_empty():
		var ph: Array = []
		for a in e.agents:
			ph.append(float((e.rota.get("planned_h", {}) as Dictionary).get((a as NpcAgent).id, 0.0)))
		ph.sort()
		var m := 0.0
		for v: float in ph:
			m += v
		m /= maxf(ph.size(), 1)
		print("  rota (last plan, next 7 days): planned h/person  min %.1f  mean %.1f  max %.1f  Gini %.3f  unassigned %d" % [
			ph[0], m, ph[-1], _gini(ph), (e.rota.get("unassigned", []) as Array).size()])
		print("  rota kept: %.0f of %.0f h of rota work done by the people it named" % [_rota_kept, _rota_total])
		if _who:
			for ag in e.agents:
				var pp: Person = people.get((ag as NpcAgent).id, null)
				var per := e.routine.persona_of((ag as NpcAgent).id)
				var cats := e.labour.by_category((ag as NpcAgent).id, 0, 999999999)
				print("    %s %-10s work %.1f h/wk  planned %.1f  maxday %.0f  %s" % [(ag as NpcAgent).id, NpcPersona.chronotype_label(per),
					float(pp.hours.get("work", 0.0)) / 6.8 * 7.0 if pp != null else 0.0,
					float((e.rota.get("planned_h", {}) as Dictionary).get((ag as NpcAgent).id, 0.0)), float(per["max_h_day"]), str(cats)])


func _probe_light(n: int, days: float, routine: String) -> void:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(n, "tu", Vector2.ZERO)
	c.routine = _routine_for(routine)
	var ctx := func(tt: float) -> Dictionary:
		return {"registry": reg, "hour_of_day": fposmod(tt, 24.0), "abs_hours": tt, "routine": c.routine}
	var people: Dictionary = {}
	var t := START_H
	c.tick(t, ctx.call(t))
	var end := START_H + days * 24.0
	while t < end - 1e-9:
		t += STEP_H
		c.tick(t, ctx.call(t))
		if t < WARMUP_H:
			continue
		for i in c.count():
			if c.alive[i] != 1:
				continue
			var p: Person = people.get(i, null)
			if p == null:
				p = Person.new()
				people[i] = p
			var cat := _cat_light(c, i)
			p.add(cat, STEP_H)
			if p.label == "":
				p.label = NpcPersona.chronotype_label(c.routine.persona_of(c.ids[i]))
			p.track_sleep(cat == "sleep", t)
			var in_toilet := cat == "toilet"
			if in_toilet and not p.was_toilet:
				p.toilet_visits += 1
				_visit_started(t)
				if c.poop_now[i] == 1:
					p.poo_visits += 1
			p.was_toilet = in_toilet
	_report("LIGHT tier", people, days - (WARMUP_H - START_H) / 24.0)
