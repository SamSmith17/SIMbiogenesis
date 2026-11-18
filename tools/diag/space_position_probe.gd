extends RefCounted

## Sandbox, read-only: what resolving every tagged space's position costs,
## by target kind (the population tick does it every tick).
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/space_position_probe.gd


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 240:
		await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	var bridge: Object = sgv.get("_npc_population") if sgv != null else null
	if bridge == null:
		return {"ok": false, "why": "no population bridge"}
	var registry: SpaceRegistry = bridge.call("_find_registry", main)
	if registry == null:
		return {"ok": false, "why": "no registry"}
	var by_kind := {}
	for rep in 3:
		for item in registry.spaces:
			var sp: Dictionary = item
			var kind := str((sp.get("target", {}) as Dictionary).get("kind", ""))
			var npts := ((sp.get("target", {}) as Dictionary).get("poly", []) as Array).size()
			var t0 := Time.get_ticks_usec()
			registry.resolve_position(sp, main)
			var us := Time.get_ticks_usec() - t0
			if rep == 2:
				var row: Array = by_kind.get(kind, [0, 0, 0, 0])
				row[0] += 1
				row[1] += us
				row[2] = maxi(int(row[2]), us)
				row[3] += npts
				by_kind[kind] = row
	for kind in by_kind:
		var r: Array = by_kind[kind]
		print("spacepos %-10s %4d spaces  %8.2f ms total  max %6.2f ms  avg poly %d pts" % [
			str(kind), int(r[0]), float(r[1]) / 1000.0, float(r[2]) / 1000.0,
			int(r[3]) / maxi(int(r[0]), 1)])
	var t1 := Time.get_ticks_usec()
	registry.refresh_positions(func(space: Dictionary) -> Variant:
		return registry.resolve_position(space, main))
	print("spacepos refresh_positions %.2f ms, revision %d" % [
		float(Time.get_ticks_usec() - t1) / 1000.0, registry.revision])
	return {"ok": true}
