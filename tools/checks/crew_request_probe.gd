extends RefCounted

## "Build with a crew" from a designer, on a real world with people (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/crew_request_probe.gd -Label crew_request -Timeout 600
## CrewBuildRequest.queue_design (what every designer's 👷 button calls) places
## a PACKED kit crate ahead of the player carrying the design, hands it to the
## deploy director (a project lands on a board, the crews are pinned), and
## reports the labour estimate; the MSAA preset rule and the hazard fold are
## pinned offline (render_profile_selftest, the settings panel compile).

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("crew-request %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var gv := ServiceLocator.graph()
	_ok(loader != null and gv != null, "loader + graph view")
	if loader == null or gv == null:
		return {"ok": false, "fails": _fails}
	# A population must be running for a crew to exist: festival mode seeds one.
	if main.has_method("open_festival_mode") and not bool(main.call("festival_mode_active")):
		main.call("open_festival_mode")
		await _frames(tree, 30)
	var sd: Object = gv.call("site_deploy") if gv.has_method("site_deploy") else null
	_ok(sd != null, "the deploy director exists")
	var spec := DomeLabSpec.resolve((DomeLabPresets.builtin("2v_conduit")["spec"] as Dictionary).duplicate(true)) \
		if not DomeLabPresets.builtin("2v_conduit").is_empty() else DomeLabSpec.resolve({})
	var r := CrewBuildRequest.queue_design(main, DomeLabBuilder.MODEL_ID,
		{"domelab_spec": DomeLabSpec.to_json_safe(spec)})
	print("crew-request: %s" % str(r))
	_ok(bool(r.get("ok", false)), "the request is accepted (%s)" % str(r.get("error", "")))
	if bool(r.get("ok", false)):
		var crate_id := str(r.get("crate_id", ""))
		var rec: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
		_ok(bool(rec.get("packed", false)), "the kit is placed packed")
		_ok(rec.get("domelab_spec") is Dictionary, "the kit carries the design")
		_ok(str(rec.get("model_id", "")) == DomeLabBuilder.MODEL_ID, "as a dome")
		_ok(float(r.get("hours", 0.0)) > 0.0, "a labour estimate (%.1f h)" % float(r.get("hours", 0.0)))
		var player := main.find_child("Player", true, false) as Node3D
		if player != null:
			var d := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))).distance_to(
				Vector2(player.global_position.x, player.global_position.z))
			_ok(d > 4.0 and d < 14.0, "the crate stands ahead of the player (%.1f m)" % d)
		await _frames(tree, 10)
		var found := not str(r.get("project_id", "")).is_empty()
		var bridge: Variant = gv.call("npc_population_bridge")
		var pinned := bridge != null and not (bridge.get("_all_hands") as Dictionary).is_empty()
		print("crew-request: project id='%s', all hands=%s" % [str(r.get("project_id", "")), str(pinned)])
		_ok(found or pinned, "the crew took the job (a project on a board, or all hands pinned)")
		loader.call("delete_prop_by_id", crate_id)
	return {"ok": _fails.is_empty(), "fails": _fails}
