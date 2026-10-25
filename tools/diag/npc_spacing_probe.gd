extends SceneTree

## Where do simulated people end up ON TOP of each other? (NPC improvement
## pass, 2026-10-25.) Runs a camp through both tiers on the crowd selftest's
## synthetic site for two days and tallies, every sim-tick, how many pairs of
## STANDING people are inside each other (< 0.3 m = one spot, < 0.6 m =
## touching, < 0.9 m = inside personal space), the same for sleepers and
## for walkers passing through each other, and how many travellers are
## heading for the SAME destination. Prints the activity pairs behind the
## worst bucket, so the generator that stacks people is named rather than
## guessed at. Offline, deterministic; --import first.
##   godot --headless --path . --script tools/diag/npc_spacing_probe.gd [-- --days=2 --n=24 --routine=festival|default]

const SAME_M := 0.3
const TOUCH_M := 0.6
const SPACE_M := 0.9


func _init() -> void:
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.reset_custom_names_for_test()
	var args := OS.get_cmdline_user_args()
	var days := 2.0
	var n := 24
	var routine := "festival"
	for a in args:
		if a.begins_with("--days="):
			days = float(a.substr(7))
		elif a.begins_with("--n="):
			n = int(a.substr(4))
		elif a.begins_with("--routine="):
			routine = a.substr(10)
	print("NPC SPACING PROBE  n=%d days=%.1f routine=%s" % [n, days, routine])
	_probe_full(n, days, routine)
	_probe_light(n, days, routine)
	quit(0)


func _square(c: Vector2, half: float) -> Array:
	return [[c.x - half, c.y - half], [c.x + half, c.y - half], [c.x + half, c.y + half], [c.x - half, c.y + half]]


func _site() -> SpaceRegistry:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(60, 0), 8)}, "kitchen", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-60, 30), 8)}, "restroom", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, 70), 8)}, "water_point", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, -80), 8)}, "sleep", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-45, -45), 8)}, "shower", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(55, 55), 8)}, "fire_circle", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-70, -60), 10)}, "center_camp", 0)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(90, -40), 6)}, "art", 0)
	reg.refresh_positions(func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null))
	return reg


func _routine_for(kind: String) -> NpcRoutine:
	return NpcRoutine.festival_day() if kind == "festival" else NpcRoutine.default_day()


class Tally:
	var same := 0
	var touch := 0
	var space := 0
	var sleep_same := 0
	var sleep_pairs := 0
	var walk_cross := 0
	var dest_same := 0
	var standing_pairs := 0
	var samples := 0
	var same_by: Dictionary = {}
	var dest_by: Dictionary = {}

	func add_pair(d: float, label: String) -> void:
		standing_pairs += 1
		if d < SAME_M:
			same += 1
			same_by[label] = int(same_by.get(label, 0)) + 1
		if d < TOUCH_M:
			touch += 1
		if d < SPACE_M:
			space += 1

	func report(title: String) -> void:
		print("--- %s: %d samples ---" % [title, samples])
		print("  standing pairs: %d   < %.1f m: %d   < %.1f m: %d   < %.1f m: %d"
			% [standing_pairs, SAME_M, same, TOUCH_M, touch, SPACE_M, space])
		print("  sleeping pairs: %d   on one spot (< %.1f m): %d" % [sleep_pairs, SAME_M, sleep_same])
		print("  walkers passing through each other (< 0.4 m): %d" % walk_cross)
		print("  travellers heading for one spot (< %.1f m): %d" % [SAME_M, dest_same])
		var keys := same_by.keys()
		keys.sort_custom(func(a, b): return int(same_by[a]) > int(same_by[b]))
		for k in keys.slice(0, 8):
			print("    same spot  %-32s %d" % [k, same_by[k]])
		var dk := dest_by.keys()
		dk.sort_custom(func(a, b): return int(dest_by[a]) > int(dest_by[b]))
		for k in dk.slice(0, 6):
			print("    same dest  %-32s %d" % [k, dest_by[k]])


func _probe_full(n: int, days: float, routine: String) -> void:
	var reg := _site()
	var e := NpcPopulationEngine.new()
	e.configure(n, "pr", Vector2.ZERO)
	e.routine = _routine_for(routine)
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var tally := Tally.new()
	var step := 1.0 / 30.0
	var t := 8.0
	var ctx := func(tt: float) -> Dictionary:
		return {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(tt, 24.0),
			"abs_hours": tt, "camp_home": Vector2.ZERO, "camp_seed": "pr", "routine": e.routine}
	e.tick(t, ctx.call(t))
	var end := 8.0 + days * 24.0
	while t < end - 1e-9:
		t += step
		e.tick(t, ctx.call(t))
		if t < 14.0:
			continue
		tally.samples += 1
		var ags: Array = e.agents
		for i in ags.size():
			var a: NpcAgent = ags[i]
			for j in range(i + 1, ags.size()):
				var b: NpcAgent = ags[j]
				var d := a.pos.distance_to(b.pos)
				var a_doing := a.state == NpcAgent.State.DOING
				var b_doing := b.state == NpcAgent.State.DOING
				var a_sleep := a_doing and a.activity == "sleep"
				var b_sleep := b_doing and b.activity == "sleep"
				if a_sleep and b_sleep:
					tally.sleep_pairs += 1
					if d < SAME_M:
						tally.sleep_same += 1
				elif a_doing and b_doing and not a_sleep and not b_sleep:
					tally.add_pair(d, _lbl(a.activity, a.target_space_type) + " | " + _lbl(b.activity, b.target_space_type))
				elif a.state == NpcAgent.State.TRAVELING and b.state == NpcAgent.State.TRAVELING:
					if d < 0.4:
						tally.walk_cross += 1
					if a.target_pos.distance_to(b.target_pos) < SAME_M:
						tally.dest_same += 1
						var k := _lbl(a.activity, a.target_space_type) + " | " + _lbl(b.activity, b.target_space_type)
						tally.dest_by[k] = int(tally.dest_by.get(k, 0)) + 1
	tally.report("FULL tier")


func _probe_light(n: int, days: float, routine: String) -> void:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(n, "pr", Vector2.ZERO)
	c.routine = _routine_for(routine)
	var tally := Tally.new()
	var step := 1.0 / 30.0
	var t := 8.0
	var ctx := func(tt: float) -> Dictionary:
		return {"registry": reg, "hour_of_day": fposmod(tt, 24.0), "abs_hours": tt, "routine": c.routine}
	c.tick(t, ctx.call(t))
	var end := 8.0 + days * 24.0
	while t < end - 1e-9:
		t += step
		c.tick(t, ctx.call(t))
		if t < 14.0:
			continue
		tally.samples += 1
		var cnt := c.count()
		var ps: Array = []
		for i in cnt:
			ps.append(c.pos_at(i, t))
		for i in cnt:
			if c.alive[i] != 1:
				continue
			for j in range(i + 1, cnt):
				if c.alive[j] != 1:
					continue
				var d: float = (ps[i] as Vector2).distance_to(ps[j])
				var a_doing := c.state[i] == CrowdCohort.S_DOING or c.state[i] == CrowdCohort.S_QUEUE
				var b_doing := c.state[j] == CrowdCohort.S_DOING or c.state[j] == CrowdCohort.S_QUEUE
				var a_sleep := a_doing and c.act[i] == CrowdCohort.A_SLEEP
				var b_sleep := b_doing and c.act[j] == CrowdCohort.A_SLEEP
				if a_sleep and b_sleep:
					tally.sleep_pairs += 1
					if d < SAME_M:
						tally.sleep_same += 1
				elif a_doing and b_doing and not a_sleep and not b_sleep:
					tally.add_pair(d, _lbl(str(CrowdCohort.ACT_NAMES[c.act[i]]), c.space_type[i]) + " | "
						+ _lbl(str(CrowdCohort.ACT_NAMES[c.act[j]]), c.space_type[j]))
				elif c.state[i] == CrowdCohort.S_TRAVEL and c.state[j] == CrowdCohort.S_TRAVEL:
					if d < 0.4:
						tally.walk_cross += 1
					var da := Vector2(c.bx[i], c.bz[i])
					var db := Vector2(c.bx[j], c.bz[j])
					if da.distance_to(db) < SAME_M:
						tally.dest_same += 1
						var k := _lbl(str(CrowdCohort.ACT_NAMES[c.act[i]]), c.space_type[i]) + " | " \
							+ _lbl(str(CrowdCohort.ACT_NAMES[c.act[j]]), c.space_type[j])
						tally.dest_by[k] = int(tally.dest_by.get(k, 0)) + 1
	tally.report("LIGHT tier")


static func _lbl(act: String, stype: String) -> String:
	var a := act if not act.is_empty() else "free"
	return a + ("@" + stype if not stype.is_empty() else "")
