extends SceneTree

## Builds the forklift from the player's GLB (if present) and prints the tree
## ForkliftRig drives: Mast / Carriage / Load positions, the fork tip, and the
## carriage's rest height. Headless, read-only.


func _initialize() -> void:
	var exists := ResourceLoader.exists(ForkliftBuilder.GLB_PATH)
	print("forklift probe: GLB present = %s" % exists)
	var node := ForkliftBuilder.build_node({}, "Forklift")
	var mast := node.get_node_or_null("Mast") as Node3D
	var carriage := node.get_node_or_null("Mast/Carriage") as Node3D
	var load_node := node.get_node_or_null("Mast/Carriage/Load") as Node3D
	print("forklift probe: body = %s" % (node.get_node_or_null("Body") != null))
	print("forklift probe: mast = %s carriage = %s load = %s" % [mast != null, carriage != null, load_node != null])
	if mast:
		print("  mast pos %s" % mast.position)
	if carriage:
		print("  carriage pos %s rest_y %s children %d" % [carriage.position, carriage.get_meta("rest_y", "?"), carriage.get_child_count()])
	if load_node:
		print("  load (root frame) %s" % ForkliftBuilder._rel(load_node, node).origin)
	print("  fork tip z %.3f" % ForkliftBuilder.fork_reach_z())
	var pts := PackedVector3Array()
	ForkliftBuilder._collect_points(node, node, pts)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	print("  whole truck bounds %s .. %s (size %s)" % [lo, hi, hi - lo])
	if carriage:
		var cp := PackedVector3Array()
		ForkliftBuilder._collect_points(carriage, node, cp)
		var clo := Vector3(INF, INF, INF)
		var chi := -clo
		for p in cp:
			clo = clo.min(p)
			chi = chi.max(p)
		print("  carriage parts bounds %s .. %s" % [clo, chi])
	print("forklift probe: %s" % ("PASS" if mast and carriage and load_node else "FAIL"))
	node.free()
	quit()
