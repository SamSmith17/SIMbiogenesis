extends RefCounted

## A placement started OUTSIDE PlacedPropsUI (the intermodal unit designer,
## the tri-clamp / ESP labs, the SCAD store) must still follow the crosshair
## and commit on a click. They used to call begin_placement without handing it
## to PlacedPropsUI, so the ghost froze green where it was first aimed and
## clicks did nothing. Sandbox only:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/placement_ghost_check.gd -Label placement_ghost

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("placement-ghost %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var player := main.find_child("Player", true, false) as Node3D
	_ok(player != null, "a map with a player")
	if player == null:
		return {"ok": false, "failures": _fails}
	var layer: PlacedPropLayer = PlacedPropService._layer_for_main(main)
	var before: int = layer.props.size() if layer != null else -1
	var tid := str(IntermodalUnits.templates()[0].get("id", "")) if not IntermodalUnits.templates().is_empty() else ""
	var spec := {"template": tid, "params": IntermodalUnits.defaults(tid)}
	var r: Dictionary = PlacedPropService.begin_placement(main, IntermodalUnitBuilder.MODEL_ID,
		{"record_extra": {"intermodal_spec": spec}})
	_ok(bool(r.get("ok", false)), "placement starts")
	await _settle(tree, 6)
	var ppui := main.find_child("PlacedPropsUI", true, false)
	_ok(ppui != null and ppui.is_processing(), "PlacedPropsUI drives the ghost")
	var ghost := PlacedPropService._ghost_node as Node3D
	_ok(ghost != null and ghost.visible, "the ghost is shown")
	var p0 := ghost.global_position if ghost != null else Vector3.ZERO
	player.rotation.y += deg_to_rad(40.0)
	await _settle(tree, 6)
	var p1 := ghost.global_position if is_instance_valid(ghost) else p0
	_ok(p0.distance_to(p1) > 0.5, "the ghost follows the crosshair (moved %.2f m)" % p0.distance_to(p1))
	await HarnessInput.click(vp, vp.get_visible_rect().size * 0.5)
	await _settle(tree, 10)
	_ok(not PlacedPropService.is_placement_active(), "a click places it (placement ended)")
	if before >= 0:
		var after: int = PlacedPropService._layer_for_main(main).props.size()
		_ok(after == before + 1, "one prop was added (%d -> %d)" % [before, after])
	if PlacedPropService.is_placement_active():
		PlacedPropService.cancel_placement()
	return {"ok": _fails.is_empty(), "failures": _fails}
