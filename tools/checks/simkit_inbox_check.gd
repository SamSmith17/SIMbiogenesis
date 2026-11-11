extends RefCounted

## A design an AI tool submitted reaches the player as an experiment fork
## (core/simkit/simkit_inbox.gd + the Compare window's "From AI tools").
## Sandbox, any world:
##
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/simkit_inbox_check.gd -Label simkit_inbox
##
## Writes one inbox entry carrying a real built graph (the SIMKIT_GRAPH env
## var names a kernel run's graph.json; else the world's own graph) with a
## Home Assistant link and a scene path planted in it, opens Compare in A vs B,
## presses "From AI tools", imports the entry, and checks: the button counts
## the entry, a fork named "AI: …" exists and is B, its graph lost the planted
## link and path, the world's own graph is untouched, the entry left the inbox.
## Then A vs B runs the fork for a day. Byte-restores the experiments file.

const Inbox := preload("res://core/simkit/simkit_inbox.gd")

var _fails: Array = []
var _dir := "user://screenshots/simkit_inbox"


func _ok(cond: bool, what: String) -> void:
	print("simkit-inbox %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


## Items and wires only: the world's own sim keeps writing levels meanwhile.
func _structure(m: GraphModel) -> String:
	var ids: Array = []
	for it in m.items:
		ids.append(str(it.get("id", "")))
	for c in m.connections:
		ids.append(str(c.get("id", "")))
	ids.sort()
	return ",".join(ids)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for i in 20:
		await tree.process_frame
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") if gv != null else null
	_ok(model != null, "a graph")
	if model == null:
		return {"ok": false, "fails": _fails}
	var exp_path := ExperimentStore.path_for_view(gv)
	var had := FileAccess.file_exists(exp_path)
	var bytes := FileAccess.get_file_as_string(exp_path) if had else ""
	var world_sig := _structure(model)

	var graph: Dictionary = {}
	var gp := OS.get_environment("SIMKIT_GRAPH")
	if not gp.is_empty() and FileAccess.file_exists(gp):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(gp))
		if parsed is Dictionary:
			graph = parsed
	if graph.is_empty():
		graph = model.serialize()
	var items: Array = graph.get("items", [])
	_ok(not items.is_empty(), "a graph to send (%d items, %s)" % [items.size(), "kernel run" if not gp.is_empty() else "the world's"])
	if not items.is_empty():
		var it0: Dictionary = items[0]
		it0["device_path"] = "/root/Main/Player"
		(it0["specs"] as Dictionary)["ha_links"] = {"power": "switch.real_pump"}
		(it0["specs"] as Dictionary)["scene_device_path"] = "/root/Main/Player"
	DirAccess.make_dir_recursive_absolute(Inbox.DIR)
	var entry := {"v": 1, "id": "inbox_check", "name": "Probe design", "note": "planted by the inbox check",
		"site": WorldPaths.active_world_id(), "created": Time.get_unix_time_from_system(),
		"summary": {"verdict": "SUSTAINED", "days": 366, "fails": [], "bottlenecks": ["cistern was empty 0 h"]},
		"graph": graph}
	var ep := Inbox.DIR.path_join("inbox_check.json")
	var f := FileAccess.open(ep, FileAccess.WRITE)
	f.store_string(JSON.stringify(entry))
	f.close()

	var view: Node = main.call("open_compare_view", PackedFloat64Array([NAN, NAN]), {"mode": "ab"})
	for i in 10:
		await tree.process_frame
	var btn: Button = view.get("_inbox_btn")
	_ok(btn != null and btn.text.contains("(1)"), "the button counts the waiting design (%s)" % (btn.text if btn else "no button"))
	if btn != null:
		# Through the button's own transform: a full-screen modal is zoomed.
		await HarnessInput.click(main.get_viewport(), btn.get_global_transform_with_canvas() * (btn.size / 2.0))
	for i in 6:
		await tree.process_frame
	var menu: PopupMenu = view.get("_inbox_menu")
	_ok(menu != null and menu.visible and menu.get_item_count() >= 2, "a REAL click opens the inbox menu")
	DirAccess.make_dir_recursive_absolute(_dir)
	main.get_viewport().get_texture().get_image().save_png(_dir.path_join("01_menu.png"))
	if menu != null:
		menu.id_pressed.emit(0)
		menu.hide()
	for i in 6:
		await tree.process_frame
	var store: ExperimentStore = view.get("_store")
	var fid := store.find_by_name("AI: Probe design") if store != null else ""
	_ok(not fid.is_empty(), "the import made a fork named “AI: Probe design”")
	var b_id: String = view.call("_sel_id", view.get("_b_opt"))
	_ok(b_id == fid, "the fork is selected as B")
	var fg: Dictionary = store.get_fork(fid).get("graph", {}) if not fid.is_empty() else {}
	var it: Dictionary = (fg.get("items", [{}]) as Array)[0] if not (fg.get("items", []) as Array).is_empty() else {}
	_ok(not it.has("device_path") and not (it.get("specs", {}) as Dictionary).has("ha_links") \
		and not (it.get("specs", {}) as Dictionary).has("scene_device_path"), "the planted link and paths were stripped")
	_ok(not FileAccess.file_exists(ep) and FileAccess.file_exists(Inbox.DIR.path_join("imported/inbox_check.json")),
		"the entry left the inbox")
	_ok(_structure(model) == world_sig, "the world's own graph did not change (items and wires)")
	main.get_viewport().get_texture().get_image().save_png(_dir.path_join("02_imported.png"))

	# A vs B on the fork for a day.
	view.call("_select_span", "next_24h")
	view.call("_on_run")
	var t0 := Time.get_ticks_msec()
	while bool(view.call("is_running")) and Time.get_ticks_msec() - t0 < 240000:
		await tree.process_frame
	var res: Dictionary = view.call("last_result")
	_ok(not res.is_empty(), "A vs B ran with the imported fork (%d s)" % ((Time.get_ticks_msec() - t0) / 1000))
	main.get_viewport().get_texture().get_image().save_png(_dir.path_join("03_ab.png"))
	if view.has_method("close"):
		view.call("close")

	# Leave the sandbox as found.
	if had:
		var w := FileAccess.open(exp_path, FileAccess.WRITE)
		w.store_string(bytes)
		w.close()
	elif FileAccess.file_exists(exp_path):
		DirAccess.remove_absolute(exp_path)
	DirAccess.remove_absolute(Inbox.DIR.path_join("imported/inbox_check.json"))
	print("simkit-inbox: %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
