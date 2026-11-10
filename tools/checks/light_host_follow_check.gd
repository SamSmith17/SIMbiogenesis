extends RefCounted

## J lights move with the placed prop they hang in (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/light_host_follow_check.gd -Label light_hosts
## A cargo container is placed near the player; an omni inside it, a string
## strung through it and an omni on open ground beside it are placed through
## the Light Studio's own calls (checkpoint / add / commit). The prop editor's
## path (update_prop_record) moves and turns the container: the two inside
## follow it, the one outside stays. The gumball preview moves the light
## nodes only. move_prop_at (crews, Elevation drags) carries them too; a
## detached light stays put; deleting the container leaves its lights where
## they stand, on the world. Removes everything it added.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("light-hosts %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var player := main.get_node_or_null("Player") as Node3D
	if loader == null or player == null:
		_ok(false, "a TerrainLoader world with a player")
		return {"ok": false, "fails": _fails}
	var at := player.global_position + Vector3(8, 0, 0)
	var placed := PlacedPropService.place_model_at_xz(main, "cargo_container", at.x, at.z)
	var pid := str(placed.get("prop_id", ""))
	_ok(not pid.is_empty(), "a container placed")
	await _frames(tree, 3)
	var rec := PlacedPropService.get_prop_record(main, pid).duplicate(true)
	var frame := PlacedPropRuntime.model_world_xf(rec, TerrainSurfaceQuery.ground_y_callable(main))
	var node := PlacedPropRuntime.find_by_prop_id(main, pid)
	_ok(node != null and frame.is_equal_approx(LightHosts.node_frame(node)),
		"the record's model frame is where the container stands")
	var bb := LightHosts.local_bounds(node) if node != null else AABB()
	_ok(bb.size.x > 2.0, "the container's bounds measured (%s)" % bb.size)
	var mid := frame * bb.get_center()
	var inside := mid + frame.basis.orthonormalized() * Vector3(0, bb.size.y * 0.3, 0)

	PlacedLightService.checkpoint(main)
	var omni := PlacedLightService.add_point_light(main, "omni", inside, Vector3.ZERO)
	PlacedLightService.commit(main)
	PlacedLightService.checkpoint(main)
	var axis := frame.basis.orthonormalized() * Vector3(bb.size.x * 0.3, 0, 0)
	var str_id := PlacedLightService.add_string(main, [inside - axis, inside + axis])
	PlacedLightService.commit(main)
	PlacedLightService.checkpoint(main)
	var away := frame.origin + Vector3(0, 1.0, 0) + frame.basis.orthonormalized().z.normalized() * (bb.size.z + 6.0)
	var lone := PlacedLightService.add_point_light(main, "omni", away, Vector3.ZERO)
	PlacedLightService.commit(main)
	var layer := PlacedLightService.get_layer(main)
	_ok(str(layer.find_light(omni).get("host_id", "")) == pid, "the light inside is on the container")
	_ok(str(layer.find_light(str_id).get("host_id", "")) == pid, "the string through it is on the container")
	_ok(str(layer.find_light(lone).get("host_id", "x")).is_empty(), "the light on open ground is on nothing")

	# The gumball preview: nodes move, records do not.
	var patch := {"x": float(rec["x"]) + 5.0, "z": float(rec["z"]) + 2.0,
		"yaw": float(rec.get("yaw", 0.0)) + 90.0}
	loader.call("preview_prop", pid, patch)
	var ln := PlacedLightRuntime.find_node(main, omni)
	var rec_after_preview := layer.position_of(layer.find_light(omni))
	_ok(rec_after_preview.distance_to(inside) < 0.01 and ln != null and ln.global_position.distance_to(inside) > 3.0,
		"the preview moves the light node, not its record")

	# The prop editor's commit.
	PlacedPropService.update_prop_record(main, pid, patch, true)
	await _frames(tree, 2)
	var rec2 := PlacedPropService.get_prop_record(main, pid)
	var frame2 := PlacedPropRuntime.model_world_xf(rec2, TerrainSurfaceQuery.ground_y_callable(main))
	var want := frame2 * (frame.affine_inverse() * inside)
	var got := layer.position_of(layer.find_light(omni))
	_ok(got.distance_to(want) < 0.05, "the light inside followed the move and turn (%.3f m off)" % got.distance_to(want))
	var pins := PlacedLightLayer.waypoints_of(layer.find_light(str_id))
	_ok(pins.size() == 2 and pins[1].distance_to(frame2 * (frame.affine_inverse() * (inside + axis))) < 0.05,
		"the string's pins followed")
	_ok(layer.position_of(layer.find_light(lone)).distance_to(away) < 0.01, "the light outside stayed put")
	ln = PlacedLightRuntime.find_node(main, omni)
	_ok(ln != null and ln.global_position.distance_to(want) < 0.05, "the light node stands where its record says")
	var node2 := PlacedPropRuntime.find_by_prop_id(main, pid)
	_ok(node2 != null and LightHosts.find_host(main, [got]) == pid, "it is still inside the moved container")

	# Crews / Elevation drags.
	var before := layer.position_of(layer.find_light(omni))
	PlacedPropService.move_prop_at(main, pid, float(rec2["x"]) - 3.0, float(rec2["z"]))
	await _frames(tree, 2)
	var after := layer.position_of(layer.find_light(omni))
	_ok(absf((after - before).x + 3.0) < 0.05 and absf((after - before).z) < 0.05,
		"move_prop_at carries the light (%s)" % (after - before))

	# Detach, move again: it stays.
	PlacedLightService.checkpoint(main)
	PlacedLightService.set_attached(main, [omni], false)
	PlacedLightService.commit(main)
	var pinned := layer.position_of(layer.find_light(omni))
	var rec3 := PlacedPropService.get_prop_record(main, pid)
	PlacedPropService.update_prop_record(main, pid, {"x": float(rec3["x"]) + 2.0}, true)
	_ok(layer.position_of(layer.find_light(omni)).is_equal_approx(pinned), "a detached light stays put")
	PlacedLightService.checkpoint(main)
	PlacedLightService.set_attached(main, [omni], true)
	PlacedLightService.commit(main)
	_ok(str(layer.find_light(omni).get("host_id", "")) == pid, "attaching again finds the container")

	# Delete the container: its lights stay where they stand.
	var pos_before_del := layer.position_of(layer.find_light(str_id))
	loader.call("delete_prop_by_id", pid)
	await _frames(tree, 2)
	_ok(str(layer.find_light(str_id).get("host_id", "x")).is_empty()
		and layer.position_of(layer.find_light(str_id)).is_equal_approx(pos_before_del),
		"deleting the container leaves its lights on the world")

	PlacedLightService.delete_ids(main, [omni, str_id, lone])
	PlacedLightService.save(main)
	return {"ok": _fails.is_empty(), "fails": _fails}
