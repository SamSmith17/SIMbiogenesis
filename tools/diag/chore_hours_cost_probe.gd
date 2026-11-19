extends RefCounted

## Sandbox, read-only: what NpcPopulationEngine spends asking each agent's
## chore hours (two full board scans per agent per substep), against the
## engines' whole tick (the bridge's npc_full_tick span), with the clock at
## 60x and the graph closed. Prints per engine: agents, chores, ms for one
## round of _assigned_hours_for over its roster.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/chore_hours_cost_probe.gd

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var v: Node = main.find_child("SystemGraphView", true, false)
	if v == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var bridge: Object = v.call("npc_population_bridge")
	if bridge == null:
		return {"ok": false, "why": "no bridge"}
	main.set("time_scale", 60.0 / 3600.0)
	PerfMonitor.set_enabled(true)
	var engines: Dictionary = bridge.get("_engines")
	var t := float(main.call("get_absolute_hours"))
	var total_round := 0.0
	var rows := 0
	for iid in engines:
		var eng: Object = engines[iid]
		if eng == null:
			continue
		var agents: Array = eng.get("agents")
		var board: Object = eng.get("chore_board")
		var nch := (board.get("chores") as Array).size() if board != null else 0
		eng.call("_assigned_hours_for", "x", t)
		var t0 := Time.get_ticks_usec()
		for a in agents:
			eng.call("_assigned_hours_for", str((a as Object).get("id")), t)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		total_round += ms
		rows += 1
		if rows <= 12:
			print("chorecost: %s %d agents, %d chores: %.3f ms a round" % [str(iid), agents.size(), nch, ms])
	print("chorecost: %d full engines, one round of chore hours for every agent %.3f ms" % [rows, total_round])
	# The engines' tick as the game runs it.
	var ticks: Array = []
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 8000:
		await tree.process_frame
		var lf: Dictionary = PerfMonitor.last_frame
		if lf.has("npc_full_tick"):
			ticks.append(float(lf["npc_full_tick"]))
	ticks.sort()
	if ticks.size() > 0:
		print("chorecost: npc_full_tick over %d ticks: median %.2f ms, worst %.2f ms" % [
			ticks.size(), float(ticks[ticks.size() / 2]), float(ticks[-1])])
	return {"ok": true}
