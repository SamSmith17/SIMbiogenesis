extends RefCounted

## Sandbox, read-only: the timeline's venue-set spans on a festival world. Does
## the space registry's revision move while nothing is edited, how many sets
## does the window hold, and what does building them cost?
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/set_spans_probe.gd


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 120:
		await tree.process_frame
	var tl: Node = main.get_node_or_null("TerrainLoader")
	if tl == null:
		tl = main.find_child("TerrainLoader", true, false)
	var reg: SpaceRegistry = tl.get("npc_spaces") if tl != null else null
	if reg == null:
		return {"ok": false, "why": "no registry"}
	var timeline: Node = main.get_node_or_null("UILayer/TimelineUI")
	main.set("time_scale", 60.0 / 3600.0)
	var revs: Array = []
	var keys: Array = []
	for _s in 8:
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1000:
			await tree.process_frame
		revs.append(reg.revision)
		keys.append(str(timeline.get("_set_spans_key")) if timeline != null else "?")
	print("setspans: registry revision over 8 s: %s" % str(revs))
	print("setspans: timeline set-span keys over 8 s: %s" % str(keys))
	var with_prog := 0
	var slots := 0
	for s in reg.spaces:
		var p: Array = (s as Dictionary).get("program", [])
		if not p.is_empty():
			with_prog += 1
			slots += p.size()
	var win: PackedFloat64Array = timeline.call("_track_window") if timeline != null else PackedFloat64Array([0.0, 168.0])
	var t1 := Time.get_ticks_usec()
	var evs := ScheduledEvents.from_programs(reg.spaces, win[0], win[0] + win[1])
	var ms := float(Time.get_ticks_usec() - t1) / 1000.0
	print("setspans: %d spaces, %d with a programme (%d slots); window %.0f h holds %d sets; built in %.2f ms" % [
		reg.spaces.size(), with_prog, slots, win[1], evs.size(), ms])
	return {"ok": true}
