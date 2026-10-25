extends RefCounted
## Cut every festival camp's water and watch thirst become BLOCKED (sandbox).
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/camp_water_cut_probe.gd
##
## A camp's habitat marks a kind starved when its wired tank is dry
## (ResourceFlowEngine._process_habitat), the bridge hands that to both tiers
## (set_starved) and a thirsty person then reads as blocked on thirst. Prints,
## every half second of real time, how many camps carry "water" in
## starved_kinds and how many people are blocked on thirst, so a starved flag
## that comes and goes shows up as a sawtooth rather than a single reading.
## Read-only: the run is a sandbox and nothing is saved.

var _fails := 0
var _passes := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		_passes += 1
		print("water-cut-check: PASS - %s" % what)
	else:
		_fails += 1
		print("water-cut-check: FAIL - %s" % what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	# The player's testing switches would make every camp's supply ideal.
	PopTestPrefs.reset_defaults()
	PopTestPrefs.set_easy_override(false)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "the systems graph is up")
	if sgv == null:
		return {"ok": false}
	var model: Variant = sgv.get("model")
	var bridge: Variant = sgv.call("npc_population_bridge")
	var camps: Array = sgv.call("festival_camps")
	_ok(not camps.is_empty(), "the world has festival camps (%d)" % camps.size())
	var hab_ids: Array = []
	var tanks := 0
	for c in camps:
		for it in model.get_items_in_scope(str(c["scope"])):
			var d: Dictionary = it
			var sp: Dictionary = (d.get("specs", {}) as Dictionary).duplicate(true)
			if str(sp.get("role", "")) == "habitat":
				hab_ids.append(str(d["id"]))
			elif str(d.get("type", "")) == "resource" and str(sp.get("resource_kind", "")) == "water":
				sp["level"] = 0.0
				model.update_item(str(d["id"]), {"specs": sp})
				tanks += 1
	var flow: Variant = sgv.get("_resource_flow")
	if flow != null and flow.has_method("clear_timelines"):
		flow.call("clear_timelines")
	print("water-cut-check: cut %d water tanks across %d camps" % [tanks, hab_ids.size()])
	main.set("time_scale", 0.2)
	var saw_starved := 0
	var starved_now := 0
	var blocked_now := 0
	var samples := 0
	var flips := 0
	var last := -1
	for k in 120:
		await tree.create_timer(0.5).timeout
		var st := 0
		var bl := 0
		var all_blocked := {}
		var acts := {}
		var tiers := {}
		var thirst_avg := 0.0
		var nsum := 0
		for hid in hab_ids:
			var hs: Dictionary = (model.get_item(str(hid)) as Dictionary).get("specs", {})
			if (hs.get("starved_kinds", []) as Array).has("water"):
				st += 1
			var sm: Dictionary = bridge.call("summary_for", str(hid))
			bl += int((sm.get("blocked", {}) as Dictionary).get("thirst", 0))
			for nb in (sm.get("blocked", {}) as Dictionary):
				all_blocked[nb] = int(all_blocked.get(nb, 0)) + int(sm["blocked"][nb])
			for a in (sm.get("activities", {}) as Dictionary):
				acts[a] = int(acts.get(a, 0)) + int(sm["activities"][a])
			var tr := str(bridge.call("tier_of", str(hid)))
			tiers[tr] = int(tiers.get(tr, 0)) + 1
			var cnt := int(sm.get("count", 0))
			thirst_avg += float((sm.get("avg_needs", {}) as Dictionary).get("thirst", 0.0)) * float(cnt)
			nsum += cnt
		if k % 10 == 0:
			var top: Array = acts.keys()
			top.sort_custom(func(x, y) -> bool: return int(acts[x]) > int(acts[y]))
			var tops := PackedStringArray()
			for j in mini(top.size(), 6):
				tops.append("%s %d" % [str(top[j]), int(acts[top[j]])])
			print("water-cut-check:   %05.2f h  tiers %s  thirst avg %.2f  blocked %s  doing: %s" % [
				float(main.get("day_time")), str(tiers), thirst_avg / float(maxi(nsum, 1)),
				str(all_blocked), ", ".join(tops)])
		if last >= 0 and (st > 0) != (last > 0):
			flips += 1
		last = st
		saw_starved = maxi(saw_starved, st)
		starved_now = st
		blocked_now = bl
		samples += 1
		if k % 4 == 0:
			print("water-cut-check: t+%4.1fs  camps starved of water %d / %d  people blocked on thirst %d" % [
				0.5 * float(k + 1), st, hab_ids.size(), bl])
	main.set("time_scale", 0.0)
	print("water-cut-check: starved-flag flips %d over %d samples" % [flips, samples])
	_ok(saw_starved > 0, "cutting the water marks camps starved of water (peak %d)" % saw_starved)
	_ok(starved_now >= hab_ids.size() / 2,
		"the starved flag holds while the tanks stay dry (%d of %d camps at the end)" % [starved_now, hab_ids.size()])
	_ok(blocked_now > 0, "people are blocked on thirst at the end (%d)" % blocked_now)
	print("water-cut-check: %d passed, %d failed — %s" % [_passes, _fails, "PASS" if _fails == 0 else "FAIL"])
	return {"ok": _fails == 0}
