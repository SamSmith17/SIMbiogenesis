extends RefCounted

## Props standing on a prop move, pack, copy and delete with it (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/prop_hosts_check.gd -Label prop_hosts
## A carport is placed near the player with two EZ-ups attached to it as
## OWNED parts (PlacedPropHosts.attach, owned) and a third attached but not
## owned. The carport is then moved and turned through every move path —
## PlacedPropService.update_prop_record (the prop editor's commit),
## PlacedPropService.move_prop_at (crews, Elevation drags),
## TerrainLoader.update_prop_record (OSM / full rebuild) and
## TerrainLoader.save_prop_from_node (the grab controller's hold-drag) — and
## after each every child must stand at host × its local pose, record AND
## node. The gumball preview (TerrainLoader.preview_prop) moves the child
## nodes, not their records. Packing the carport packs its parts (not the
## guest); unpacking unpacks them. A duplicate (id erased, as the prop editor
## hands it over) copies the two parts onto the copy. Deleting the carport
## deletes its parts and sets the guest down. Removes everything it added.

const HOST_MODEL := "carport"
const KID_MODEL := "ez_up"
const TOL_M := 0.05

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("prop-hosts %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _rec(main: Node, id: String) -> Dictionary:
	return PlacedPropService.get_prop_record(main, id)


## How far the child's record frame is from host × local (m, plus 1 m per
## radian of rotation error).
func _off(main: Node, host_id: String, kid_id: String, local: Array) -> float:
	var want := PlacedPropHosts.carried(PlacedPropHosts.record_frame(main, _rec(main, host_id)), local)
	var got := PlacedPropHosts.record_frame(main, _rec(main, kid_id))
	var rot := (want.basis.orthonormalized().inverse() * got.basis.orthonormalized()).get_rotation_quaternion().get_angle()
	return got.origin.distance_to(want.origin) + rot


func _node_xz_off(main: Node, kid_id: String) -> float:
	var node := PlacedPropRuntime.find_by_prop_id(main, kid_id)
	if node == null or not is_instance_valid(node):
		return INF
	var r := _rec(main, kid_id)
	return Vector2(node.global_position.x - float(r["x"]), node.global_position.z - float(r["z"])).length()


func _all_followed(main: Node, host: String, kids: Array, locals: Dictionary, what: String) -> void:
	var worst := 0.0
	var worst_node := 0.0
	for k in kids:
		worst = maxf(worst, _off(main, host, str(k), locals[k]))
		worst_node = maxf(worst_node, _node_xz_off(main, str(k)))
	_ok(worst < TOL_M, "%s: children follow the host (worst %.4f)" % [what, worst])
	_ok(worst_node < TOL_M, "%s: child nodes stand on their records (worst %.4f m)" % [what, worst_node])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var player := main.get_node_or_null("Player") as Node3D
	if loader == null or player == null:
		_ok(false, "a TerrainLoader world with a player")
		return {"ok": false, "fails": _fails}
	var layer := PlacedPropService._layer_for_main(main)
	var at := player.global_position + Vector3(12, 0, 4)
	var host := str(PlacedPropService.place_model_at_xz(main, HOST_MODEL, at.x, at.z).get("prop_id", ""))
	var kid_a := str(PlacedPropService.place_model_at_xz(main, KID_MODEL, at.x + 1.5, at.z - 1.0).get("prop_id", ""))
	var kid_b := str(PlacedPropService.place_model_at_xz(main, KID_MODEL, at.x - 1.5, at.z + 1.0).get("prop_id", ""))
	var guest := str(PlacedPropService.place_model_at_xz(main, KID_MODEL, at.x, at.z + 3.0).get("prop_id", ""))
	_ok(not host.is_empty() and not kid_a.is_empty() and not kid_b.is_empty() and not guest.is_empty(),
		"a carport and three EZ-ups placed")
	await _frames(tree, 3)
	# Give the parts a turn of their own so rotation is tested too.
	PlacedPropService.update_prop_record(main, kid_a, {"yaw": 30.0}, true)
	PlacedPropService.update_prop_record(main, host, {"yaw": 15.0}, true)

	_ok(PlacedPropHosts.attach(main, kid_a, host, true), "attach part A (owned)")
	_ok(PlacedPropHosts.attach(main, kid_b, host, true), "attach part B (owned)")
	_ok(PlacedPropHosts.attach(main, guest, host, false), "attach the guest (not owned)")
	_ok(not PlacedPropHosts.attach(main, host, kid_a), "a host cannot stand on its own part")
	var kids := [kid_a, kid_b, guest]
	var locals := {}
	for k in kids:
		locals[k] = PlacedPropHosts.link_of(_rec(main, str(k)))["local"]
	_ok(PlacedPropHosts.children_of(layer, host).size() == 3, "three children on the carport")
	_ok(PlacedPropHosts.owned_children(layer, host).size() == 2, "two of them owned")
	_all_followed(main, host, kids, locals, "attached")

	# 1. The prop editor's commit.
	var r := _rec(main, host)
	PlacedPropService.update_prop_record(main, host,
		{"x": float(r["x"]) + 6.0, "z": float(r["z"]) + 2.0, "yaw": float(r.get("yaw", 0.0)) + 70.0}, true)
	await _frames(tree, 2)
	_all_followed(main, host, kids, locals, "PlacedPropService.update_prop_record")

	# 2. Crews / Elevation drags.
	r = _rec(main, host)
	PlacedPropService.move_prop_at(main, host, float(r["x"]) - 4.0, float(r["z"]) + 5.0)
	await _frames(tree, 2)
	_all_followed(main, host, kids, locals, "PlacedPropService.move_prop_at")

	# 3. The loader's own update (full rebuild).
	r = _rec(main, host)
	loader.call("update_prop_record", host, {"x": float(r["x"]) + 3.0, "yaw": float(r.get("yaw", 0.0)) - 40.0})
	await _frames(tree, 3)
	_all_followed(main, host, kids, locals, "TerrainLoader.update_prop_record")

	# 4. The grab controller: the host node is carried, then saved from it.
	var hnode := PlacedPropRuntime.find_by_prop_id(main, host)
	_ok(hnode != null, "the carport node exists")
	if hnode != null:
		var gp := hnode.global_position
		var to := Vector2(gp.x - 5.0, gp.z - 3.0)
		var dy := TerrainSurfaceQuery.ground_height_at(main, to.x, to.y) - TerrainSurfaceQuery.ground_height_at(main, gp.x, gp.z)
		hnode.global_position = Vector3(to.x, gp.y + dy, to.y)
		loader.call("save_prop_from_node", hnode)
		await _frames(tree, 2)
		_ok(Vector2(float(_rec(main, host)["x"]) - to.x, float(_rec(main, host)["z"]) - to.y).length() < TOL_M,
			"the carport record is where it was dropped")
		_all_followed(main, host, kids, locals, "TerrainLoader.save_prop_from_node")

	# 5. The gumball preview: child nodes move, records do not.
	r = _rec(main, host).duplicate(true)
	var kid_rec_before := _rec(main, kid_a).duplicate(true)
	var patch := {"x": float(r["x"]) + 8.0, "z": float(r["z"]), "yaw": float(r.get("yaw", 0.0)) + 90.0}
	loader.call("preview_prop", host, patch)
	var shown := r.duplicate(true)
	shown.merge(patch, true)
	var want_a := PlacedPropHosts.carried(PlacedPropHosts.record_frame(main, shown), locals[kid_a])
	var anode := PlacedPropRuntime.find_by_prop_id(main, kid_a)
	_ok(anode != null and Vector2(anode.global_position.x - want_a.origin.x,
		anode.global_position.z - want_a.origin.z).length() < TOL_M,
		"the preview moves the part's node with the carport")
	_ok(absf(float(_rec(main, kid_a)["x"]) - float(kid_rec_before["x"])) < 1e-4,
		"the preview leaves the part's record alone")
	loader.call("preview_prop", host, {})   # back to the saved pose
	await _frames(tree, 1)
	anode = PlacedPropRuntime.find_by_prop_id(main, kid_a)
	_ok(anode != null and _node_xz_off(main, kid_a) < TOL_M, "a preview back to the record puts the node back")

	# 6. Pack / unpack: the parts go with it, the guest does not.
	loader.call("set_prop_packed", host, true)
	await _frames(tree, 3)
	_ok(bool(_rec(main, host).get("packed", false)), "the carport packed")
	_ok(bool(_rec(main, kid_a).get("packed", false)) and bool(_rec(main, kid_b).get("packed", false)),
		"its parts packed with it")
	_ok(not bool(_rec(main, guest).get("packed", false)), "the guest was not packed")
	loader.call("set_prop_packed", host, false)
	await _frames(tree, 3)
	_ok(not bool(_rec(main, host).get("packed", false)) and not bool(_rec(main, kid_a).get("packed", false))
		and not bool(_rec(main, kid_b).get("packed", false)), "unpacked together")

	# 7. Duplicate (the prop editor erases the id): the parts are copied.
	var copy := _rec(main, host).duplicate(true)
	for k in ["id", "burn", "graph_item_id", "stowed_in", "packed", "build_state"]:
		copy.erase(k)
	copy["x"] = float(copy["x"]) + 14.0
	var host2 := str(loader.call("duplicate_prop_record", copy))
	await _frames(tree, 3)
	_ok(not host2.is_empty(), "the carport duplicated")
	var parts2 := PlacedPropHosts.owned_children(layer, host2)
	_ok(parts2.size() == 2, "the copy has its two parts (%d)" % parts2.size())
	_ok(PlacedPropHosts.children_of(layer, host2).size() == 2, "the guest was not copied")
	_ok(PlacedPropHosts.children_of(layer, host).size() == 3, "the original keeps its three")
	var worst2 := 0.0
	for p in parts2:
		worst2 = maxf(worst2, _off(main, host2, str(p), PlacedPropHosts.link_of(_rec(main, str(p)))["local"]))
	_ok(worst2 < TOL_M, "the copied parts stand on the copy (%.4f)" % worst2)
	var la := PlacedPropHosts.xf_from_array(locals[kid_a])
	var matched := false
	for p in parts2:
		if PlacedPropHosts.xf_from_array(PlacedPropHosts.link_of(_rec(main, str(p)))["local"]).is_equal_approx(la):
			matched = true
	_ok(matched, "a copied part sits where part A sits on the original")
	# The copy moves its own parts, not the original's.
	var a_before := _rec(main, kid_a).duplicate(true)
	PlacedPropService.update_prop_record(main, host2, {"z": float(_rec(main, host2)["z"]) + 3.0}, true)
	await _frames(tree, 2)
	_ok(absf(float(_rec(main, kid_a)["z"]) - float(a_before["z"])) < 1e-4, "moving the copy leaves the original's parts")

	# 8. Delete: the parts go, the guest comes down to the ground.
	loader.call("delete_prop_by_id", host)
	await _frames(tree, 3)
	_ok(_rec(main, host).is_empty(), "the carport deleted")
	_ok(_rec(main, kid_a).is_empty() and _rec(main, kid_b).is_empty(), "its parts deleted with it")
	_ok(not _rec(main, guest).is_empty() and PlacedPropHosts.host_of(_rec(main, guest)).is_empty(),
		"the guest stays, on the ground")
	_ok(PlacedPropRuntime.find_by_prop_id(main, kid_a) == null, "no node left for a deleted part")

	# Clean up.
	loader.call("delete_prop_by_id", host2)
	loader.call("delete_prop_by_id", guest)
	await _frames(tree, 2)
	for p in parts2:
		_ok(_rec(main, str(p)).is_empty(), "the copy's part went with the copy")
	return {"ok": _fails.is_empty(), "fails": _fails}
