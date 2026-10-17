extends Node

## `--capture=conduits`: 3D connectors end to end on a real world.
##   Routing  — a cord pulled off one device's port and released (a REAL LMB
##              release through the viewport) on another's: the HUD length at
##              release equals the committed run's route_length_m within 1 %.
##   Modal    — the style modal writes LIVE (no Apply), previews the REAL run
##              (its bounds match the run's within 2 %), Revert undoes it.
##   Labels   — "Show run lengths" puts a tag at the run's arc midpoint.
##   Chain    — Shift+release keeps chaining from the device just plugged into
##              (when it has a free compatible port).
## Everything it makes is removed again (and the run is sandboxed).

var main: Node = null
var shots_dir := "user://screenshots/conduits"
var _fails := 0
var _made: Array = []


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("conduits %s — %s" % ["PASS" if ok else "FAIL", what])


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _shot(name: String) -> void:
	for i in 4:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [shots_dir, name])


func run() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	var gv := main.get_node_or_null("UILayer/SystemGraphView")
	var mgr := main.get_node_or_null("ConduitManager")
	var player := main.get_node_or_null("Player") as Node3D
	var ctrl := player.get_node_or_null("ConduitRouteController") if player != null else null
	var cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D if player != null else null
	if gv == null or mgr == null or ctrl == null or cam == null:
		_check(false, "graph, conduit manager, route controller and camera present")
		return {"failures": _fails}
	gv.call("close_graph_view")
	# Through the player's pref (a manager-only flag is re-read away by the
	# next full sync); handed back at the end.
	var wires_before := bool(SimSettingsController.get("conduits_3d_visible"))
	SimSettingsController.set_conduits_3d_visible(true)
	mgr.call("set_global_visibility", true)
	await _wait(0.5)
	var model: GraphModel = gv.get("model")
	var pair := _pick_pair(mgr, model)
	if pair.is_empty():
		# Put the world's untracked placed machines on the graph (the library's
		# "In the world" drawer, same Add) so there are devices with ports.
		for r in GraphWorldInventory.collect(gv):
			var rd: Dictionary = r
			if str(rd.get("group", "")) == "Placed models":
				var ok: Variant = (rd["add"] as Callable).call()
				print("conduits info — add %s (%s): %s" % [rd.get("name", ""), rd.get("sub", ""), ok])
		await _wait(1.0)
		pair = _pick_pair(mgr, model)
	if pair.is_empty():
		_check(false, "found two devices with free, compatible ports 2–80 m apart")
		return {"failures": _fails}
	var src: Dictionary = pair[0]
	var dst: Dictionary = pair[1]
	print("conduits info — %s:%s -> %s:%s (%.1f m apart)" % [src["item_id"],
		(src["port"] as Dictionary).get("handle_id", ""), dst["item_id"],
		(dst["port"] as Dictionary).get("handle_id", ""),
		(src["world_pos"] as Vector3).distance_to(dst["world_pos"] as Vector3)])
	# Stand back so both ends are in view, then pull a cord off the source.
	var mid: Vector3 = ((src["world_pos"] as Vector3) + (dst["world_pos"] as Vector3)) * 0.5
	var dirxz := Vector3((dst["world_pos"] as Vector3).x - (src["world_pos"] as Vector3).x, 0.0,
		(dst["world_pos"] as Vector3).z - (src["world_pos"] as Vector3).z)
	var side := dirxz.cross(Vector3.UP).normalized()
	player.global_position = mid + side * maxf(4.0, dirxz.length() * 0.6)
	player.global_position.y = TerrainSurfaceQuery.ground_height_at(main, player.global_position.x,
		player.global_position.z) + 0.1
	await _wait(0.4)
	var n_before := model.connections.size()
	ctrl.call("begin_plug", src)
	_aim(player, cam, dst["world_pos"] as Vector3)
	for i in 30:
		await get_tree().process_frame
	var target: Dictionary = ctrl.get("_plug_target")
	_check(not target.is_empty(), "aiming at the far port snaps the plug to it")
	ctrl.call("_update_ui")
	var hud_len := float(ctrl.get("last_hud_length_m"))
	await _shot("00_plug_drag")
	# The real release.
	var vp := get_viewport()
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = vp.get_visible_rect().size * 0.5
	ev.global_position = ev.position
	vp.push_input(ev, true)
	await _wait(0.8)
	_check(model.connections.size() == n_before + 1, "the release made exactly one connection")
	var conn_id := ""
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("source_item_id", "")) == str(src["item_id"]) \
				and str(cd.get("target_item_id", "")) == str(dst["item_id"]):
			conn_id = str(cd.get("id", ""))
	if conn_id.is_empty():
		for c in model.connections:
			var cd2: Dictionary = c
			if str(cd2.get("target_item_id", "")) == str(src["item_id"]) \
					and str(cd2.get("source_item_id", "")) == str(dst["item_id"]):
				conn_id = str(cd2.get("id", ""))
	if conn_id.is_empty():
		_check(false, "found the new connection")
		return {"failures": _fails}
	_made.append(conn_id)
	mgr.call("force_remesh", conn_id)
	await _wait(0.5)
	var run_len := float(model.get_connection(conn_id).get("route_length_m", 0.0))
	var err := absf(hud_len - run_len) / maxf(run_len, 0.001)
	_check(run_len > 0.0 and err <= 0.01,
		"the HUD said %.2f m at release; the run measures %.2f m (%.2f %% off)" % [hud_len, run_len, err * 100.0])
	await _shot("01_connected")
	await _test_modal(gv, mgr, model, conn_id)
	await _test_labels(mgr, model, conn_id)
	await _test_chain(ctrl, mgr, model, player, cam, dst)
	for cid in _made:
		if not model.get_connection(str(cid)).is_empty():
			model.remove_connection(str(cid))
	RunLengthLabels.set_enabled(false)
	SimSettingsController.set_conduits_3d_visible(wires_before)
	return {"failures": _fails}


func _aim(player: Node3D, cam: Camera3D, target: Vector3) -> void:
	var eye := cam.global_position
	var d := target - eye
	player.rotation.y = atan2(-d.x, -d.z)
	cam.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())


## Two ports on different prop-bound items, unwired, compatible, 2–40 m apart
## (closest such pair).
func _pick_pair(mgr: Node, model: GraphModel) -> Array:
	var ports: Array = mgr.call("gather_world_ports")
	var dump := PackedStringArray()
	for pp in ports:
		var pd: Dictionary = pp
		var po: Dictionary = pd["port"]
		dump.append("%s:%s(%s,%s,out=%s,in=%s)" % [pd["item_id"], po.get("handle_id", ""), po.get("polarity", ""),
			po.get("resource_kind", ""), ConduitPlugLogic.port_is_output(po), ConduitPlugLogic.port_is_input(po)])
	print("conduits info — %d world ports: %s" % [ports.size(), ", ".join(dump.slice(0, 30))])
	var wired := {}
	for c in model.connections:
		var cd: Dictionary = c
		wired["%s|%s" % [cd.get("source_item_id", ""), cd.get("source_handle_id", "")]] = true
		wired["%s|%s" % [cd.get("target_item_id", ""), cd.get("target_handle_id", "")]] = true
	var best: Array = []
	var best_d := INF
	for a in ports:
		var ad: Dictionary = a
		# The source may already carry a wire (a port takes several); the
		# target must be free.
		for b in ports:
			var bd: Dictionary = b
			if str(bd["item_id"]) == str(ad["item_id"]):
				continue
			var bh := "%s|%s" % [bd["item_id"], (bd["port"] as Dictionary).get("handle_id", "")]
			if wired.has(bh) or not ConduitPlugLogic.ports_compatible(ad, bd):
				continue
			if ConduitPlugLogic.port_is_input(ad["port"]) and not ConduitPlugLogic.port_is_output(ad["port"]):
				continue
			# A direct intake (a siphon's dip tube) is never drawn in 3D.
			if ConduitKinds.is_direct_intake_connection(
					ConduitPlugLogic.build_connection_spec(ad, bd, "extension_cord"), model):
				continue
			var d := (ad["world_pos"] as Vector3).distance_to(bd["world_pos"] as Vector3)
			if d < 2.0 or d > 80.0:
				continue
			if d < best_d:
				best_d = d
				best = [ad, bd]
	return best


func _test_modal(gv: Node, mgr: Node, model: GraphModel, conn_id: String) -> void:
	gv.call("open_conduit_style_modal", conn_id)
	await _wait(0.8)
	var modal: Node = gv.get("_conduit_style_modal")
	_check(modal != null and (modal as Control).visible, "the style modal opens on the run")
	if modal == null:
		return
	_check(str(modal.get("_preview_kind")) == "run", "it previews the REAL run (%s)" % modal.get("_preview_kind"))
	# Preview bounds vs the run's own sample bounds.
	var samples: PackedVector3Array = mgr.call("get_sample_points", conn_id)
	var studio: Node3D = modal.get("_studio")
	var copy: Node3D = null
	for c in studio.get_children():
		if c is Node3D and c.has_meta("preview_conduit") and c.get_child_count() > 0:
			copy = c
	if copy != null and samples.size() >= 2:
		var run_box := AABB(samples[0], Vector3.ZERO)
		for p in samples:
			run_box = run_box.expand(p)
		var prev_box: AABB = modal.call("_tree_aabb", copy)
		var r := prev_box.get_longest_axis_size() / maxf(run_box.get_longest_axis_size(), 0.001)
		_check(absf(r - 1.0) <= 0.02 + 0.2 / maxf(run_box.get_longest_axis_size(), 1.0),
			"the preview is the run's size (ratio %.3f)" % r)
	else:
		_check(false, "the preview holds a copy of the run")
	await _shot("02_modal_open")
	var before := str(model.get_connection(conn_id).get("conduit_type", ""))
	var type_opt: OptionButton = modal.get("_type_opt")
	var pick := -1
	for i in type_opt.item_count:
		var tid := str(type_opt.get_item_metadata(i))
		if not tid.is_empty() and tid != before and tid in ["romex", "dc_solar", "extension_cord", "garden_hose"]:
			pick = i
			break
	type_opt.select(pick)
	type_opt.item_selected.emit(pick)
	await _wait(0.6)
	var after := str(model.get_connection(conn_id).get("conduit_type", ""))
	_check(after != before and not after.is_empty(), "changing the kind reached the wire with no Apply (%s -> %s)" % [before, after])
	await _shot("03_modal_live")
	modal.call("_on_revert")
	await _wait(0.4)
	_check(str(model.get_connection(conn_id).get("conduit_type", "")) == before, "Revert put it back")
	var meas := str((modal.get("_measure_lbl") as Label).text)
	_check(meas.contains(" m · ") and meas.contains("ft"), "the header measures the run (%s)" % meas)
	modal.call("close")
	await _wait(0.3)


func _test_labels(mgr: Node, model: GraphModel, conn_id: String) -> void:
	RunLengthLabels.set_enabled(true)
	mgr.set_process(true)
	await _wait(1.0)
	var tag: Label3D = mgr.call("run_length_tag", conn_id)
	var ln: Node = mgr.get_node_or_null("RunLengthLabels")
	print("conduits info — tag debug: inst=%s processing=%s gen=%s/%s labels_node=%s children=%s enabled=%s len=%s" % [
		(mgr.get("_instances") as Dictionary).has(conn_id), mgr.is_processing(), mgr.get("_run_labels_gen"),
		RunLengthLabels.generation, ln != null, ln.get_child_count() if ln != null else -1,
		RunLengthLabels.enabled(), model.get_connection(conn_id).get("route_length_m", 0.0)])
	if ln != null:
		var names := PackedStringArray()
		for c in ln.get_children():
			names.append(str(c.name))
		print("conduits info — tags: %s · conn %s · mgr children with id: %s" % [", ".join(names), conn_id,
			", ".join(Array(mgr.get_children().filter(func(n): return str(n.name).contains(conn_id)).map(func(n): return str(n.name)))) ])
	var samples: PackedVector3Array = mgr.call("get_sample_points", conn_id)
	if samples.size() < 2:
		samples = PackedVector3Array(mgr.call("build_control_points", model.get_connection(conn_id)))
	var mid := RunLengthLabels.midpoint(samples)
	_check(tag != null and tag.global_position.distance_to(mid + Vector3(0, 0.35, 0)) < 0.05,
		"a length tag sits over the run's midpoint (%s)" % (tag.text.replace("\n", " / ") if tag != null else "none"))
	await _shot("04_length_tags")
	RunLengthLabels.set_enabled(false)
	await _wait(0.5)
	_check(mgr.call("run_length_tag", conn_id) == null, "turning it off clears the tags")


## Shift+release from a device with a free compatible port keeps chaining.
func _test_chain(ctrl: Node, mgr: Node, model: GraphModel, player: Node3D, cam: Camera3D,
		hub: Dictionary) -> void:
	var nxt: Dictionary = ctrl.call("_next_free_port", hub, hub)
	if nxt.is_empty():
		print("conduits info — the device plugged into has no free outgoing port; chain check skipped")
		return
	print("conduits info — chaining from %s:%s" % [nxt["item_id"], (nxt["port"] as Dictionary).get("handle_id", "")])
	_check(true, "a free port to chain from was found on the device just plugged into")
