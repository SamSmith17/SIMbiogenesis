class_name NpcChoreBoard
extends RefCounted

## The site's work queue: non-survival jobs people do once their critical
## needs are quiet — hauling, tending machines, repairs, maintenance.
##
## Labour is expressed in `chore_hours`, the ResourceKind the process-recipe
## system already consumes, so NPC work SUPPLIES the existing ledger rather
## than forking a parallel economy.
##
## A chore record:
##   { id, label,
##     target: {kind: "prop"|"graph_item"|"space", id: "..."},
##     space_type: "",            # optional space the work happens at
##     chore_hours: 0.5,          # labour to complete one run
##     window: {start_h, end_h},  # daily availability (hour of day)
##     repeat: "daily"|"once"|"on_demand"|"every_n"|"weekly",
##     repeat_days: 1,            # every_n: the N
##     repeat_dow: [],            # weekly: weekdays, 0 = Monday
##     catch_up: true,            # weekly: a missed slot stays due
##     exposure: "indoor"|"sheltered"|"outdoor",
##     priority: 0,               # lower sorts first
##     assigned_to: "",           # agent id, "" = anyone free
##     depends_on: [],            # chore ids that must complete first (v2)
##     min_workers: 1,            # quorum — credits ZERO until this many
##                                # people stand at it (barn-raising gate)
##     max_workers: 1,            # crew cap (two people fit at one drill)
##     progress_h: 0.0,
##     workers: [],               # agents currently on it (runtime only)
##     done_day: -1 }             # sim-day index this run completed
##
## v2 (dependency-aware crew board — PACKING_PLAN.md Phase 6.5 step 0):
## `depends_on` holds a chore back until every dependency is COMPLETE for
## its cycle (a deleted dependency unblocks — the player removing a chore
## means "skip that step", never a deadlock); `min_workers`/`max_workers`
## turn a chore into a crew task — claims stack to the cap, and credit()
## refuses to progress below quorum, so agents who arrive early WAIT at the
## work site until enough hands show up (the gathering is emergent, the
## agent just keeps doing a chore that pays zero until it doesn't). With
## these two, a whole NpcCrewPlan schedule drops onto the board via
## add_plan() and the roster executes the build in dependency order.
##
## Persistence rides the habitat item's specs (same change-gated path as
## pop_state), so a site's routines survive save/load with the graph.
## v1 records deserialize cleanly — every new key reads through .get
## defaults (single worker, no deps).

const VERSION := 2
## Raised from 64 for Site Projects: an assembly-steps-split linkage plan plus
## a delivery's per-crate haul chores plus the site's daily chores must coexist.
const MAX_CHORES := 160
## How long a finished one-off stays on the board before prune_completed
## retires it. Long enough that "what did we get done this week" still has
## something to show.
const KEEP_DONE_DAYS := 3

## UI-toast convenience ONLY — completion is authoritative as board STATE
## (done_day >= 0 on a repeat:"once" chore), which the SiteProject sweep in
## NpcPopulationBridge observes after each engine tick. Nothing gameplay-
## relevant may hang off this signal: it fires inside the pure engine's
## substep, where world mutation would break determinism.
signal chore_completed(chore_id: String, label: String)

var chores: Array = []
var _next_id := 1
## Site rules ("rule cards" v1 — PACKING_PLAN.md Phase 6.5): board-level
## switches the whole roster obeys, persisted with the chores. Catalog:
##   night_shift — chore windows ignored; work continues around the clock
##                 (sleep still preempts at its own threshold, so people
##                 nap when they must — an emergent shift pattern)
##   tools_down  — no chores offered at all (rest day / ceremony / strike)
var rules: Dictionary = {}
## tag -> true when at least one person on the roster is qualified.
## Refreshed by the engine each tick; RUNTIME ONLY, never serialized.
## An EMPTY dict means "skills are not configured here", which makes every
## requirement inert — that is the default and it must stay harmless.
var skill_supply: Dictionary = {}


static func create_empty() -> NpcChoreBoard:
	return NpcChoreBoard.new()


# --- authoring --------------------------------------------------------------

func add_chore(label: String, chore_hours: float, opts: Dictionary = {}) -> String:
	if chores.size() >= MAX_CHORES:
		return ""
	var min_w := maxi(int(opts.get("min_workers", 1)), 1)
	var rec := {
		"id": "chore_%d" % _next_id,
		"label": label if not label.is_empty() else "Chore %d" % _next_id,
		"target": opts.get("target", {}),
		"space_type": str(opts.get("space_type", "")),
		"chore_hours": maxf(chore_hours, 0.01),
		"window": opts.get("window", {"start_h": 8.0, "end_h": 18.0}),
		"repeat": normalize_repeat(opts.get("repeat", "daily")),
		# Only meaningful for every_n / weekly; free to carry otherwise.
		"repeat_days": maxi(int(opts.get("repeat_days", 1)), 1),
		"repeat_dow": (opts.get("repeat_dow", []) as Array).duplicate(),
		"catch_up": bool(opts.get("catch_up", true)),
		"exposure": str(opts.get("exposure", NpcWeatherGate.EXPOSURE_OUTDOOR)),
		"priority": int(opts.get("priority", 0)),
		"assigned_to": str(opts.get("assigned_to", "")),
		"requires_skill": str(opts.get("requires_skill", "")),
		"depends_on": (opts.get("depends_on", []) as Array).duplicate(),
		"min_workers": min_w,
		"max_workers": maxi(int(opts.get("max_workers", 1)), min_w),
		# Optional haul route: {from_x, from_z, to_x, to_z, strategy} —
		# brigade-strategy workers take STATION posts along this line
		# (NpcAgent._begin_chore) instead of clustering at the target.
		"haul": (opts.get("haul", {}) as Dictionary).duplicate(true),
		"progress_h": 0.0,
		"workers": [],
		"done_day": -1,
	}
	# Site Project extensions (all optional; serialize() carries unknown keys):
	#   effect        — {op, ...} world mutation dispatched ONCE by the
	#                   bridge's post-tick sweep after this chore completes
	#                   (effect_done is stamped alongside it as the flag)
	#   stage_effects — [{at: 0..1, effect: {...}}] INCREMENTAL mutations,
	#                   each fired once as progress crosses its threshold
	#                   (SiteProject.due_stage_effects; `fired` stamped per
	#                   stage) — how a bucket-brigade moves crates one by one
	#                   while the single crew chore is still in flight.
	#                   Meaningful on repeat:"once" chores only: _arm_cycle
	#                   resets progress for repeating chores but never the
	#                   fired flags, so stages would fire exactly one cycle.
	#   carry_to      — {x, z} second travel leg: the agent walks to the
	#                   target (the pickup), then CARRIES here before working
	#   held          — paused by the player; hidden from available_for
	for opt_key: String in ["effect", "carry_to"]:
		if opts.get(opt_key, null) is Dictionary and not (opts[opt_key] as Dictionary).is_empty():
			rec[opt_key] = (opts[opt_key] as Dictionary).duplicate(true)
	if opts.get("stage_effects", null) is Array and not (opts["stage_effects"] as Array).is_empty():
		rec["stage_effects"] = (opts["stage_effects"] as Array).duplicate(true)
	if bool(opts.get("held", false)):
		rec["held"] = true
	# Optional stable identity for chores minted by a system rather than
	# authored: lets the minter recognise its own chore after a reload, when
	# the generated id it remembered has been renumbered.
	if not str(opts.get("chore_key", "")).is_empty():
		rec["chore_key"] = str(opts["chore_key"])
	_next_id += 1
	chores.append(rec)
	return str(rec["id"])


func remove_chore(chore_id: String) -> bool:
	for i in chores.size():
		if str((chores[i] as Dictionary).get("id", "")) == chore_id:
			chores.remove_at(i)
			return true
	return false


func find(chore_id: String) -> Dictionary:
	for c in chores:
		if str((c as Dictionary).get("id", "")) == chore_id:
			return c
	return {}


## Find a system-minted chore by its stable key (see `chore_key`).
func find_by_key(key: String) -> Dictionary:
	if key.is_empty():
		return {}
	for c in chores:
		if str((c as Dictionary).get("chore_key", "")) == key:
			return c
	return {}


func update_chore(chore_id: String, patch: Dictionary) -> bool:
	var rec := find(chore_id)
	if rec.is_empty():
		return false
	for k in patch:
		rec[k] = patch[k]
	return true


# --- scheduling -------------------------------------------------------------

static func day_index(abs_hours: float) -> int:
	return int(floor(abs_hours / 24.0))


## Day of the week, 0 = Monday.
##
## This is FREE, and the reason is worth writing down: `abs_hours` is hours
## since proleptic-Gregorian year 1 Jan 1 00:00 (`CelestialClock.
## get_absolute_hours`), and that date was a Monday. So `day_index % 7` IS the
## real weekday — no epoch constant, no calendar plumbing, and nothing new
## crossing into this pure class, which only ever sees `abs_hours`.
##
## The one cost is a coupling to that epoch. `_test_recurrence` pins it against
## a known real date so a change to the clock's origin fails loudly here rather
## than quietly moving everyone's laundry day.
static func weekday(abs_hours: float) -> int:
	return weekday_of_day(day_index(abs_hours))


static func weekday_of_day(day: int) -> int:
	return posmod(day, 7)


## Legal `repeat` values. `on_demand` means "only when something re-arms it"
## (see `rearm`), which is how a machine republishes a job it needs done again.
const REPEATS: Array = ["daily", "once", "on_demand", "every_n", "weekly"]

## Fail CLOSED to "once".
##
## Two producers emit a BOOL here (`NpcCrewPlan.chore_specs`,
## `NpcHaul.chore_spec`) and both mean "once". `str(false)` is `"false"`, which
## matches no arm of `_is_due` and lands in its silent `return false` — a chore
## that runs once and is never due again. That is harmless TODAY only because
## `add_plan` overwrites the field, and it is exactly the hole a new repeat
## value would fall into. Normalising at both entry points closes it.
static func normalize_repeat(v: Variant) -> String:
	if v is bool:
		return "once"
	var s := str(v)
	return s if REPEATS.has(s) else "once"


## Has any of `dow` fallen between `done_day` (exclusive) and `today`?
##
## Bounded on purpose: a week or more late is unconditionally due, so a chore
## nobody has touched for a month costs the same seven iterations as one a day
## late. Without the bound this is O(days since the settlement was founded).
static func _dow_elapsed_since(done_day: int, today: int, dow: Array) -> bool:
	if today - done_day >= 7:
		return true
	for d in range(done_day + 1, today + 1):
		if dow.has(weekday_of_day(d)):
			return true
	return false


## Is this chore's daily window open at `hour_of_day`? Windows may wrap
## midnight (e.g. a 22:00-02:00 night check).
static func window_open(chore: Dictionary, hour_of_day: float) -> bool:
	var w: Dictionary = chore.get("window", {})
	var s := float(w.get("start_h", 0.0))
	var e := float(w.get("end_h", 24.0))
	var h := fposmod(hour_of_day, 24.0)
	if s <= e:
		return h >= s and h < e
	return h >= s or h < e   # wraps midnight


## When a chore comes round again.
##
##   daily      every sim-day
##   every_n    every `repeat_days` days ("water the beds every 3 days")
##   weekly     on the weekdays in `repeat_dow` (0 = Monday)
##   once       never
##   on_demand  only when something calls rearm()
##
## `catch_up` (default true) decides what a MISSED weekly slot means. True
## keeps it due — consistent with `backlog_hours`, which already models
## unworked due work as debt. False skips it, which is the right answer for a
## rotation meal: Wednesday's lunch cannot be cooked on Friday.
func _is_due(chore: Dictionary, abs_hours: float) -> bool:
	var repeat := normalize_repeat(chore.get("repeat", "daily"))
	var done_day := int(chore.get("done_day", -1))
	if done_day < 0:
		return true
	var today := day_index(abs_hours)
	match repeat:
		"daily":
			return today > done_day
		"once":
			return false
		"every_n":
			return today >= done_day + maxi(int(chore.get("repeat_days", 1)), 1)
		"weekly":
			if today <= done_day:
				return false
			var dow: Array = chore.get("repeat_dow", []) as Array
			if dow.is_empty():
				return today >= done_day + 7   # degenerate weekly: just a week
			if bool(chore.get("catch_up", true)):
				return _dow_elapsed_since(done_day, today, dow)
			return dow.has(weekday_of_day(today))
	return false   # on_demand: re-armed explicitly via rearm()


## Retire finished one-offs.
##
## Nothing has ever pruned these: a completed `once` chore sits on the board
## with done_day >= 0 forever, and MAX_CHORES (160) is a shared budget that a
## generated duty rota is about to draw on too.
##
## Skips anything a SYSTEM owns — an unfired `effect`, any `stage_effects`, or
## any `chore_key` — because SiteProjectStore.sync and the bridge's minters
## look their chores back up by id or key, and a pruned one reads as deleted.
## Returns how many went.
func prune_completed(abs_hours: float, keep_days: int = KEEP_DONE_DAYS) -> int:
	var cutoff := day_index(abs_hours) - maxi(keep_days, 0)
	var gone := 0
	for i in range(chores.size() - 1, -1, -1):
		var c: Dictionary = chores[i]
		if normalize_repeat(c.get("repeat", "daily")) != "once":
			continue
		var done := int(c.get("done_day", -1))
		if done < 0 or done > cutoff:
			continue
		if not str(c.get("chore_key", "")).is_empty():
			continue
		if c.has("stage_effects"):
			continue
		if c.has("effect") and not bool(c.get("effect_done", false)):
			continue
		chores.remove_at(i)
		gone += 1
	return gone


func rearm(chore_id: String) -> void:
	var rec := find(chore_id)
	if not rec.is_empty():
		rec["done_day"] = -1
		rec["progress_h"] = 0.0


## Start a fresh cycle for a repeating chore that has come due again.
## Completion now KEEPS progress_h at chore_hours (so remaining() stays 0 for
## the finished cycle — the fix for the re-work loop where a second claimed
## agent re-credited a done once-chore from zero); the reset moves HERE, at
## the moment the next cycle opens. Called by every reader that pairs
## _is_due with _remaining, so the aggregates see a re-due daily chore as
## full work again exactly as before.
## Has a personal assignment lapsed into "anyone"?
##
## A named assignment is a FIRST REFUSAL, not a lock. Without a hold the old
## permanent behaviour is kept byte-for-byte (`assign_hold_h` absent => 0.0 =>
## never expires), so hand-authored chores and every v1 record are unaffected.
## With one, a rostered slot whose person is asleep, eating or simply elsewhere
## opens to the rest of the crew rather than going undone — which is the
## difference between a schedule and a single point of failure.
static func _assign_expired(chore: Dictionary, abs_hours: float) -> bool:
	var hold := float(chore.get("assign_hold_h", 0.0))
	if hold <= 0.0:
		return false
	return abs_hours >= float(chore.get("assign_at_h", abs_hours)) + hold


## Clear assignments to people who are not on the roster.
##
## This is the worst failure the board has and nothing ever cleared it. An
## orphaned assignment is permanently unclaimable — no live agent id can match
## it — AND it deadlocks every DEPENDENT chore, because `_deps_met` treats a
## present-but-never-due dependency as unsatisfied. A deleted dependency
## unblocks by design; an orphan-assigned one blocks forever.
##
## Returns the freed chore ids so the caller can say who left and what it cost.
func validate_assignments(live_agent_ids: Array) -> Array:
	var live: Dictionary = {}
	for a in live_agent_ids:
		live[str(a)] = true
	var freed: Array = []
	for c in chores:
		var chore: Dictionary = c
		var who := str(chore.get("assigned_to", ""))
		if who.is_empty() or live.has(who):
			continue
		chore["assigned_to"] = ""
		chore.erase("assign_at_h")
		chore.erase("assign_hold_h")
		# Kept so the UI can say WHY this is suddenly everyone's job.
		chore["orphaned_from"] = who
		freed.append(str(chore.get("id", "")))
	return freed


func _arm_cycle(chore: Dictionary, abs_hours: float) -> void:
	if int(chore.get("done_day", -1)) < 0:
		return
	if float(chore.get("progress_h", 0.0)) <= 0.0:
		return
	if not _is_due(chore, abs_hours):
		return
	# ONCE PER CYCLE, not once per credit.
	#
	# credit() calls this before applying, and a re-due chore stays due until
	# it COMPLETES. Without this guard the sequence was: reset to 0, add a few
	# minutes, next credit resets to 0 again — forever. A repeating chore
	# could only ever finish if a single credit delivered its whole
	# chore_hours, so in practice a daily chore completed on its first day and
	# NEVER AGAIN, silently, while still consuming labour every tick.
	# Measured: two 3 h daily chores burned 99 h of crew time over four days
	# and recorded one completion.
	#
	# It hid because every test of completion used repeat:"once", where
	# _is_due goes false after the first finish and this never runs at all.
	var today := day_index(abs_hours)
	if int(chore.get("cycle_day", -1)) == today:
		return
	chore["progress_h"] = 0.0
	chore["cycle_day"] = today


## Chores this agent could pick up right now, best first. Filters by
## assignment, due-ness, window, crew-cap, dependency gates, and weather
## safety; sorts by player priority then remaining work (finish what's
## nearly done). `roster_size` > 0 also hides crew tasks whose quorum the
## whole roster cannot meet — nobody waits forever for hands that don't
## exist.
func available_for(agent_id: String, abs_hours: float, hour_of_day: float,
		weather: Dictionary = {}, roster_size: int = 0,
		fair_rank: int = 0, my_skills: Dictionary = {}) -> Array:
	if bool(rules.get("tools_down", false)):
		return []
	var night_shift := bool(rules.get("night_shift", false))
	var out: Array = []
	for c in chores:
		var chore: Dictionary = c
		_arm_cycle(chore, abs_hours)
		if bool(chore.get("held", false)):
			continue
		# Skill gating, and the rule that keeps it from HIDING work: skip this
		# chore only when somebody ELSE on site could do it instead. If nobody
		# is qualified it stays offerable to everyone — the work gets done
		# badly rather than not at all, and blocked_reason can say so. A chore
		# that silently vanishes because nobody can do it is the hygiene stall
		# wearing a hat.
		var need_skill := str(chore.get("requires_skill", ""))
		if not need_skill.is_empty() \
				and bool(skill_supply.get(need_skill, false)) \
				and not bool(my_skills.get(need_skill, false)):
			continue
		var assigned := str(chore.get("assigned_to", ""))
		if not assigned.is_empty() and assigned != agent_id \
				and not _assign_expired(chore, abs_hours):
			continue
		var workers: Array = chore.get("workers", [])
		if not workers.has(agent_id) \
				and workers.size() >= int(chore.get("max_workers", 1)):
			continue
		if roster_size > 0 and int(chore.get("min_workers", 1)) > roster_size:
			continue
		if not _is_due(chore, abs_hours):
			continue
		if not _deps_met(chore, abs_hours):
			continue
		if not night_shift and not window_open(chore, hour_of_day):
			continue
		if NpcWeatherGate.is_unsafe(weather, str(chore.get("exposure", "outdoor"))):
			continue
		out.append(chore)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		# A crew chore that is GATHERING (someone already standing at it,
		# quorum not yet met) outranks everything: the fastest way to end a
		# barn-raising stall is for every free hand to converge on it, not to
		# trickle one person per backoff cycle while the early arrivals give
		# up and leave (the quorum-thrash failure mode).
		var ga := _is_gathering(a)
		var gb := _is_gathering(b)
		if ga != gb:
			return ga
		var pa := int(a.get("priority", 0))
		var pb := int(b.get("priority", 0))
		if pa != pb:
			return pa < pb
		return _remaining(a) < _remaining(b))
	# Fair-share yield.
	#
	# The sort above is good, and deliberately untouched — gathering first,
	# then priority, then finish-what-is-nearly-done. Its problem is that it
	# is IDENTICAL for everybody, so every agent converges on options[0].
	#
	# So rather than corrupt the ordering, rotate it: somebody who is ahead
	# of the roster steps past the jobs somebody behind should get first.
	# Rank 0 (furthest behind) still gets the top job. The shift is clamped
	# below the list length, so this can never empty the list and therefore
	# can never become a stall.
	if out.size() > 1 and fair_rank > 0:
		var shift := mini(fair_rank, out.size() - 1)
		var head: Array = out.slice(0, shift)
		out = out.slice(shift)
		out.append_array(head)
	return out


## One line explaining why a chore is not moving, or "" when nothing blocks it.
##
## Its absence is exactly what made the hygiene stall invisible for a whole
## release: the sim always KNEW why nothing was happening, and no surface could
## say it. This feeds the Routines panel, the Work Planner tabs and the work
## dock tooltip — one implementation, so the surfaces cannot disagree.
##
## Returns "" for a chore that is done for its cycle (finished is not blocked)
## and for one that is simply available with nobody on it yet (idle is not
## blocked either). `name_of` resolves an agent id to a display name; without
## it the raw id is shown, which is still honest.
func blocked_reason(chore: Dictionary, abs_hours: float, hour_of_day: float,
		weather: Dictionary = {}, roster_size: int = 0,
		name_of: Callable = Callable()) -> String:
	if bool(rules.get("tools_down", false)):
		return "tools down — no work is offered"
	if bool(chore.get("held", false)):
		return "on hold"
	_arm_cycle(chore, abs_hours)
	if not _is_due(chore, abs_hours):
		return ""   # completed this cycle — finished, not blocked
	# Dependencies first: "waiting on X" explains more than any gate below.
	for dep_id in chore.get("depends_on", []):
		var dep := find(str(dep_id))
		if not dep.is_empty() and _is_due(dep, abs_hours):
			return "waiting on %s" % str(dep.get("label", "an earlier step"))
	# The anti-invisibility rule made visible: when nobody on site holds the
	# required skill the chore stays OFFERED to everyone, and this is where the
	# board says so instead of the work just quietly going worse.
	var need_skill := str(chore.get("requires_skill", ""))
	if not need_skill.is_empty() and not skill_supply.is_empty() \
			and not bool(skill_supply.get(need_skill, false)):
		return "needs %s — nobody on site is qualified, so anyone may try" \
			% NpcSkills.label(need_skill)
	if roster_size > 0 and int(chore.get("min_workers", 1)) > roster_size:
		return "needs a crew of %d — only %d people on site" % [
			int(chore.get("min_workers", 1)), roster_size]
	if not bool(rules.get("night_shift", false)) \
			and not window_open(chore, hour_of_day):
		var w: Dictionary = chore.get("window", {})
		return "outside its hours (%02d–%02d)" % [
			int(w.get("start_h", 0.0)), int(w.get("end_h", 24.0))]
	if NpcWeatherGate.is_unsafe(weather, str(chore.get("exposure", "outdoor"))):
		return "weather is too dangerous for %s work" \
			% str(chore.get("exposure", "outdoor"))
	var assigned := str(chore.get("assigned_to", ""))
	if not assigned.is_empty() and not _assign_expired(chore, abs_hours) \
			and (chore.get("workers", []) as Array).is_empty():
		var who := str(name_of.call(assigned)) if name_of.is_valid() else assigned
		return "held for %s" % who
	var workers := (chore.get("workers", []) as Array).size()
	var min_w := int(chore.get("min_workers", 1))
	if workers > 0 and workers < min_w:
		return "gathering a crew — %d of %d" % [workers, min_w]
	return ""


## Display glyph for a blocked_reason sentence, so every surface prefixes the
## same one. Derived from the sentence rather than a parallel enum: the
## sentence IS the contract, and a second channel would drift. Order matters —
## "needs a crew of 4" must not read as the skill case's "needs Electrical".
static func reason_glyph(reason: String) -> String:
	if reason.is_empty():
		return ""
	if reason.begins_with("weather"):
		return "⛅"
	if reason.begins_with("outside"):
		return "🕐"
	if reason.begins_with("waiting on"):
		return "⏳"
	if reason.begins_with("held for"):
		return "👤"
	if reason == "on hold":
		return "⏸"
	if reason.begins_with("tools down"):
		return "🛑"
	if reason.contains("crew of") or reason.begins_with("gathering"):
		return "👥"
	if reason.begins_with("needs"):
		return "🎓"
	return "⚠"


## [glyph, tooltip] identifying a SYSTEM-minted chore, [] for a player chore.
## Same single-source rule as reason_glyph: every surface that badges a row or
## guards its delete button calls this, so the vocabulary cannot fork. A
## system chore must not be hand-deleted — a keyed minter re-mints it next
## tick, and a project task deletion breaks the project's phase tracking —
## which is why the tooltip says where it IS managed. `project_chore_ids` is
## the caller's set of chore ids owned by site projects (they carry no
## chore_key; the project record tracks them by id).
static func system_badge(chore: Dictionary, project_chore_ids: Dictionary = {}) -> Array:
	var key := str(chore.get("chore_key", ""))
	if key.begins_with("mach|"):
		return ["⚙", "Minted by a machine recipe — manage it from the machine; deleting it would just re-mint"]
	if key.begins_with("duty|"):
		return ["📅", "Minted from the duty rota — manage it on the Schedule tab"]
	if key.begins_with("oncall|") or key.begins_with("need_unmet|"):
		return ["🚨", "Minted by an on-call alarm — it clears when the condition does"]
	if project_chore_ids.has(str(chore.get("id", ""))):
		return ["👷", "Part of a site project — manage it from the Site projects panel"]
	if not key.is_empty():
		return ["⚙", "System-minted — deleting it would just re-mint"]
	return []


static func _is_gathering(chore: Dictionary) -> bool:
	var min_w := int(chore.get("min_workers", 1))
	if min_w <= 1:
		return false
	var w := (chore.get("workers", []) as Array).size()
	return w > 0 and w < min_w


static func _remaining(chore: Dictionary) -> float:
	return maxf(float(chore.get("chore_hours", 0.0)) - float(chore.get("progress_h", 0.0)), 0.0)


func remaining(chore_id: String) -> float:
	return _remaining(find(chore_id))


## Every dependency complete for its cycle ("not due" = it has run). A
## dependency id that no longer exists is SATISFIED — deleting a chore
## means "skip that step", and must never deadlock its dependents.
func _deps_met(chore: Dictionary, abs_hours: float) -> bool:
	for dep_id in chore.get("depends_on", []):
		var dep := find(str(dep_id))
		if dep.is_empty():
			continue
		if _is_due(dep, abs_hours):
			return false
	return true


## Claims stack up to max_workers (idempotent per agent).
func claim(chore_id: String, agent_id: String) -> bool:
	var rec := find(chore_id)
	if rec.is_empty():
		return false
	var workers: Array = rec.get("workers", [])
	if workers.has(agent_id):
		return true
	if workers.size() >= int(rec.get("max_workers", 1)):
		return false
	workers.append(agent_id)
	rec["workers"] = workers
	# A named slot whose person did not show: the hold lapsed and somebody else
	# stepped in. Stamped ONCE, first coverer wins — the Schedule strikes the
	# original name through, and the bridge logs the substitution as a NOTE
	# (a covered shift is the system working, not an alarm).
	var assigned := str(rec.get("assigned_to", ""))
	if not assigned.is_empty() and assigned != agent_id \
			and str(rec.get("covered_by", "")).is_empty():
		rec["covered_by"] = agent_id
	return true


func release(chore_id: String, agent_id: String) -> void:
	var rec := find(chore_id)
	if not rec.is_empty():
		(rec.get("workers", []) as Array).erase(agent_id)


func release_all_for_agent(agent_id: String) -> void:
	for c in chores:
		((c as Dictionary).get("workers", []) as Array).erase(agent_id)


func worker_count(chore_id: String) -> int:
	return (find(chore_id).get("workers", []) as Array).size()


## This agent's position in the crew (claim order) — station assignment for
## brigade hauls. -1 when not on the crew.
func worker_index(chore_id: String, agent_id: String) -> int:
	return (find(chore_id).get("workers", []) as Array).find(agent_id)


## Quorum: enough hands standing at the task for work to progress.
func has_quorum(chore_id: String) -> bool:
	var rec := find(chore_id)
	if rec.is_empty():
		return false
	return (rec.get("workers", []) as Array).size() >= int(rec.get("min_workers", 1))


## Credit `hours` of effective labour. Returns the chore_hours actually
## applied (never more than what was left), so the ledger stays mass-exact.
## CREW chores (min_workers > 1) below quorum credit NOTHING — the crew
## gathers, the work waits. Single-worker chores keep v1 semantics and
## credit without a claim: the hybrid chore-confirm path (and any manual
## credit) has never claimed first, and must not start needing to.
func credit(chore_id: String, hours: float, abs_hours: float) -> float:
	var rec := find(chore_id)
	if rec.is_empty() or hours <= 0.0:
		return 0.0
	_arm_cycle(rec, abs_hours)
	if not _is_due(rec, abs_hours):
		return 0.0   # completed this cycle — a lingering claimant credits nothing
	var min_w := int(rec.get("min_workers", 1))
	if min_w > 1 and (rec.get("workers", []) as Array).size() < min_w:
		return 0.0
	var left := _remaining(rec)
	var applied := minf(hours, left)
	rec["progress_h"] = float(rec.get("progress_h", 0.0)) + applied
	if _remaining(rec) <= 0.0001:
		rec["done_day"] = day_index(abs_hours)
		# progress_h deliberately KEPT at chore_hours: remaining() must stay 0
		# for the completed cycle (see _arm_cycle). Snap it exact so the
		# 0.0001 epsilon can't leave a sliver that reads as unfinished.
		rec["progress_h"] = float(rec.get("chore_hours", 0.0))
		rec["workers"] = []
		chore_completed.emit(str(rec.get("id", "")), str(rec.get("label", "")))
	return applied


## Total labour a given agent is on the hook for today — feeds the day-plan
## strip and the free-time calculation that gates enrichment.
func assigned_hours_for(agent_id: String, abs_hours: float) -> float:
	var total := 0.0
	for c in chores:
		var chore: Dictionary = c
		_arm_cycle(chore, abs_hours)
		if str(chore.get("assigned_to", "")) != agent_id:
			continue
		if not _is_due(chore, abs_hours):
			continue
		total += _remaining(chore)
	return total


## Unassigned due work, spread across the roster — what "anyone free" costs
## each person on average.
func shared_hours_per_agent(roster_size: int, abs_hours: float) -> float:
	if roster_size <= 0:
		return 0.0
	var total := 0.0
	for c in chores:
		var chore: Dictionary = c
		_arm_cycle(chore, abs_hours)
		if not str(chore.get("assigned_to", "")).is_empty():
			continue
		if not _is_due(chore, abs_hours):
			continue
		total += _remaining(chore)
	return total / float(roster_size)


## Backlog: due work whose window has already closed today.
func backlog_hours(abs_hours: float, hour_of_day: float) -> float:
	var total := 0.0
	for c in chores:
		var chore: Dictionary = c
		_arm_cycle(chore, abs_hours)
		if not _is_due(chore, abs_hours):
			continue
		if window_open(chore, hour_of_day):
			continue
		var w: Dictionary = chore.get("window", {})
		if fposmod(hour_of_day, 24.0) > float(w.get("end_h", 24.0)):
			total += _remaining(chore)
	return total


# --- crew plans -------------------------------------------------------------

## Drop a whole NpcCrewPlan schedule onto the board (PACKING_PLAN.md Phase
## 6.5 step 0): chore_specs rows become "once" chores wired together by
## depends_on (task ids remapped to the created chore ids), quorum and crew
## caps intact — the roster then executes the build in dependency order.
## Returns the created chore ids (truncates cleanly at MAX_CHORES).
func add_plan(plan_chores: Array,
		window: Dictionary = {"start_h": 7.0, "end_h": 19.0},
		target: Dictionary = {}) -> Array:
	# ATOMIC: a plan that doesn't fit is refused whole. A truncated plan is
	# worse than none — the created head would carry dep ids that map to
	# nothing, which _deps_met treats as satisfied, silently unblocking the
	# tail of a build that never had its early phases.
	var valid := 0
	for spec in plan_chores:
		if spec is Dictionary:
			valid += 1
	if chores.size() + valid > MAX_CHORES:
		return []
	var made: Array = []
	var by_task: Dictionary = {}
	for spec in plan_chores:
		if not (spec is Dictionary):
			continue
		var d := spec as Dictionary
		var opts := {
			"repeat": "once",
			"window": window.duplicate(),
			"exposure": str(d.get("exposure", NpcWeatherGate.EXPOSURE_OUTDOOR)),
			"priority": int(d.get("priority", 0)),
			"min_workers": int(d.get("min_workers", 1)),
			"max_workers": int(d.get("max_workers", 1)),
			# Default: the whole build happens at one site (the structure) —
			# every phase inherits it so chore_pos_of sends workers there. A
			# spec row may override per task (a haul goes to ITS crate).
			"target": (d.get("target", target) as Dictionary).duplicate(true),
		}
		for opt_key: String in ["haul", "effect", "carry_to"]:
			if d.get(opt_key, null) is Dictionary and not (d[opt_key] as Dictionary).is_empty():
				opts[opt_key] = d[opt_key]
		if d.get("stage_effects", null) is Array and not (d["stage_effects"] as Array).is_empty():
			opts["stage_effects"] = d["stage_effects"]
		var cid := add_chore(str(d.get("label", "Task")),
			float(d.get("chore_hours", 0.1)), opts)
		if cid.is_empty():
			break
		by_task[str(d.get("task_id", ""))] = cid
		made.append({"cid": cid, "deps": d.get("depends_on", [])})
	var out: Array = []
	for m in made:
		var mapped: Array = []
		for dep in (m as Dictionary)["deps"]:
			if by_task.has(str(dep)):
				mapped.append(str(by_task[str(dep)]))
		update_chore(str((m as Dictionary)["cid"]), {"depends_on": mapped})
		out.append(str((m as Dictionary)["cid"]))
	return out


# --- persistence ------------------------------------------------------------

func serialize() -> Dictionary:
	var out: Array = []
	for c in chores:
		var rec: Dictionary = (c as Dictionary).duplicate(true)
		rec.erase("workers")   # runtime-only claims
		rec.erase("worker")    # v1 leftover, never persisted
		out.append(rec)
	return {"version": VERSION, "next_id": _next_id, "chores": out,
		"rules": rules.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	chores = []
	rules = (data.get("rules", {}) as Dictionary).duplicate(true)
	_next_id = int(data.get("next_id", 1))
	for item in data.get("chores", []):
		if not (item is Dictionary):
			continue
		var rec: Dictionary = (item as Dictionary).duplicate(true)
		rec["workers"] = []
		rec.erase("worker")
		# Fail closed on a value this build does not know — a save written by
		# a newer build must not resurrect as a chore that is never due.
		rec["repeat"] = normalize_repeat(rec.get("repeat", "daily"))
		chores.append(rec)
		var n := str(rec.get("id", "")).trim_prefix("chore_").to_int()
		_next_id = maxi(_next_id, n + 1)
