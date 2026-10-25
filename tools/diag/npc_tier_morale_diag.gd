extends SceneTree

## Tier equivalence under a switch: the crowd selftest's 3-day default-day
## camp in both tiers, with the step-aside (NpcAgent.loiter_enabled) on and
## off, printing mean morale and the water / food totals of each. Offline.
##   godot --headless --path . --script tools/diag/npc_tier_morale_diag.gd


func _init() -> void:
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.reset_custom_names_for_test()
	for on in [false, true]:
		NpcAgent.loiter_enabled = on
		var f := _full()
		var l := _light()
		print("loiter=%s  FULL morale %.3f (day-3 avg %.3f, loiter samples %d) water %.0f food %.1f | LIGHT morale %.3f (day-3 avg %.3f, loiter samples %d) water %.0f food %.1f"
			% [str(on), f["morale"], f["avg"], f["loiter"], f["water"], f["food"], l["morale"], l["avg"], l["loiter"], l["water"], l["food"]])
	quit(0)


func _square(c: Vector2, half: float) -> Array:
	return [[c.x - half, c.y - half], [c.x + half, c.y - half], [c.x + half, c.y + half], [c.x - half, c.y + half]]


func _site() -> SpaceRegistry:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(60, 0), 8)}, "kitchen", 30)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-60, 30), 8)}, "restroom", 30)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, 70), 8)}, "water_point", 30)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, -80), 8)}, "sleep", 30)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-45, -45), 8)}, "shower", 30)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(55, 55), 8)}, "fire_circle", 30)
	reg.refresh_positions(func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null))
	return reg


func _full() -> Dictionary:
	var reg := _site()
	var e := NpcPopulationEngine.new()
	e.configure(24, "eq", Vector2.ZERO)
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var tot := {}
	var t := 8.0
	var step := 1.0 / 30.0
	e.tick(t, {"registry": reg, "pos_of": pos_of, "hour_of_day": 8.0})
	var avg := 0.0
	var n_avg := 0
	var loiter := 0
	while t < 8.0 + 72.0 - 1e-9:
		t += step
		var d := e.tick(t, {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t, 24.0)})
		for k in d:
			tot[k] = float(tot.get(k, 0.0)) + float(d[k]) * step
		if t > 8.0 + 48.0:
			avg += e.mean_morale()
			n_avg += 1
		for a in e.agents:
			if (a as NpcAgent).activity == NpcAgent.LOITER_ACTIVITY:
				loiter += 1
	return {"morale": e.mean_morale(), "avg": avg / maxf(float(n_avg), 1.0), "loiter": loiter,
		"water": float(tot.get("water", 0.0)), "food": float(tot.get("food", 0.0))}


func _light() -> Dictionary:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(24, "eq", Vector2.ZERO)
	var tot := {}
	var t := 8.0
	var step := 1.0 / 30.0
	c.tick(t, {"registry": reg, "hour_of_day": 8.0, "abs_hours": t})
	var avg := 0.0
	var n_avg := 0
	var loiter := 0
	while t < 8.0 + 72.0 - 1e-9:
		t += step
		var d := c.tick(t, {"registry": reg, "hour_of_day": fposmod(t, 24.0), "abs_hours": t})
		for k in d:
			tot[k] = float(tot.get(k, 0.0)) + float(d[k]) * step
		if t > 8.0 + 48.0:
			avg += c.mean_morale()
			n_avg += 1
		for i in c.count():
			if c.act[i] == CrowdCohort.A_FREE and c.state[i] == CrowdCohort.S_TRAVEL:
				loiter += 1
	return {"morale": c.mean_morale(), "avg": avg / maxf(float(n_avg), 1.0), "loiter": loiter,
		"water": float(tot.get("water", 0.0)), "food": float(tot.get("food", 0.0))}
