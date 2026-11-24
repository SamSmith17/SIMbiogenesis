extends RefCounted

## Typed waste bins fill with REAL 3D items (plans/FOOD_WASTE_REALISM_PLAN.md
## Phase 8). Sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/waste_bin_check.gd -Label waste_bins -Timeout 900
## Covers: placing a bin binds a typed graph store (seed_waste_bin); the
## WasteBinRuntime pile tracks the store's ITEM LEDGER count for count; a
## scrub back LOWERS the pile (the ledger is a pure function of t); past
## capacity the heap flags Overflowing; a store with kg but no ledger draws
## its kind's representative pieces. Shots front / top / overflow.

var _fails: Array = []
var _dir := "user://screenshots/waste_bins"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("waste-bin %s: %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else " (%s)" % detail])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	print("waste-bin shot: %s" % name)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var gv := ServiceLocator.graph()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	_ok(gv != null and loader != null, "graph view + loader")
	if gv == null:
		return {"ok": false, "fails": _fails}
	var model = gv.get("model")
	var engine = gv.get("_resource_flow")
	_ok(engine != null, "flow engine")
	main.set("time_scale", 0.0)
	var h0 := float(main.call("get_absolute_hours"))
	var player: Node3D = main.get_node_or_null("Player")
	var px := player.global_position.x if player != null else 0.0
	var pz := player.global_position.z if player != null else 0.0

	# -- place a PET bin: the store binds itself -----------------------------
	var res := PlacedPropService.place_model_at_xz(main, "waste_bin", px + 5.0, pz + 2.0,
		{"bin_spec": {"kind": "pet_waste"}})
	_ok(bool(res.get("ok", false)), "a waste bin is placed")
	var pid := str(res.get("prop_id", ""))
	await _frames(tree, 6)   # seed_waste_bin is deferred
	var rec := PlacedPropService.get_prop_record(main, pid)
	var gid := str(rec.get("graph_item_id", ""))
	_ok(not gid.is_empty(), "the bin bound a graph store")
	var item: Dictionary = model.get_item(gid) if not gid.is_empty() else {}
	var sp: Dictionary = item.get("specs", {})
	_ok(str(item.get("type", "")) == "resource"
		and str(sp.get("resource_kind", "")) == "pet_waste"
		and absf(float(sp.get("capacity_qty", 0.0)) - 40.0) < 1e-6
		and str(sp.get("bound_prop_id", "")) == pid,
		"…a 40 kg pet_waste store bound to the prop", str(sp.get("resource_kind", "")))
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	var rt: Node = prop.get_node_or_null("WasteBinRuntime") if prop != null else null
	_ok(rt != null, "WasteBinRuntime attached")
	if rt == null or gid.is_empty():
		return {"ok": false, "fails": _fails}

	# -- the pile tracks the ledger, count for count --------------------------
	var led = engine.call("ensure_item_ledger", gid)
	_ok(led != null, "the typed store takes an item ledger")
	led.call("record", h0 - 0.5, "pet_bottle_500", 40, 40.0 * 0.024)
	await tree.create_timer(0.6).timeout
	var drawn: Dictionary = rt.call("drawn_counts")
	_ok(int(drawn.get("pet_bottle", 0)) == 40, "40 bottles in the ledger = 40 drawn", str(drawn))
	led.call("record", h0 - 0.1, "pet_bottle_500", 30, 30.0 * 0.024)
	await tree.create_timer(0.6).timeout
	drawn = rt.call("drawn_counts")
	_ok(int(drawn.get("pet_bottle", 0)) == 70, "30 more arrive = 70 drawn", str(drawn))
	var cam := main.get_viewport().get_camera_3d()
	var at: Vector3 = (prop as Node3D).global_position + Vector3(0, 0.6, 0)
	if cam != null:
		cam.look_at_from_position(at + Vector3(1.6, 0.9, 1.3), at, Vector3.UP)
		await tree.create_timer(0.8).timeout
		_shot(main, "01_bin_front")
		cam.look_at_from_position(at + Vector3(0.12, 2.4, 0.12), at, Vector3.UP)
		await tree.create_timer(0.6).timeout
		_shot(main, "02_bin_top")

	# -- a scrub back lowers the pile -----------------------------------------
	main.call("set_absolute_hours", h0 - 0.3)
	await tree.create_timer(0.6).timeout
	drawn = rt.call("drawn_counts")
	_ok(int(drawn.get("pet_bottle", 0)) == 40, "scrubbed back past the arrival = 40 again", str(drawn))
	main.call("set_absolute_hours", h0)
	await tree.create_timer(0.6).timeout
	drawn = rt.call("drawn_counts")
	_ok(int(drawn.get("pet_bottle", 0)) == 70, "forward again = 70", str(drawn))

	# -- overflow: past 360 L the heap climbs over the rim and says so --------
	led.call("record", h0 - 0.02, "pet_bottle_500", 330, 330.0 * 0.024)   # 400 x 1.15 L = 460 L
	await tree.create_timer(0.6).timeout
	drawn = rt.call("drawn_counts")
	_ok(int(drawn.get("pet_bottle", 0)) == 256, "the draw caps at 256 instances", str(drawn))
	var lbl := rt.get("_label") as Label3D
	_ok(lbl != null and lbl.visible and lbl.text == I18n.t("Overflowing"),
		"the Overflowing label shows", lbl.text if lbl != null else "no label")
	if cam != null:
		cam.look_at_from_position(at + Vector3(1.8, 1.3, 1.4), at + Vector3(0, 0.4, 0), Vector3.UP)
		await tree.create_timer(0.6).timeout
		_shot(main, "03_bin_overflowing")
	led.call("truncate_after", h0 - 0.05)   # tidy: back to 70

	# -- kg with no ledger: the kind's representative pieces ------------------
	var res2 := PlacedPropService.place_model_at_xz(main, "waste_bin", px + 7.2, pz + 2.0,
		{"bin_spec": {"kind": "steel_waste"}})
	var pid2 := str(res2.get("prop_id", ""))
	await _frames(tree, 6)
	var rec2 := PlacedPropService.get_prop_record(main, pid2)
	var gid2 := str(rec2.get("graph_item_id", ""))
	_ok(not gid2.is_empty(), "the second bin bound a steel_waste store")
	if not gid2.is_empty():
		var it2: Dictionary = model.get_item(gid2)
		var sp2: Dictionary = (it2.get("specs", {}) as Dictionary).duplicate(true)
		sp2["level"] = 0.1   # 8 kg of 80
		model.update_item(gid2, {"specs": sp2})
		# Specs alone are undone by the engine's tank pass: set the timeline too.
		var tl2: Object = engine.call("get_timeline", gid2)
		if tl2 != null:
			tl2.call("set_current_level", h0, 0.1)
	var prop2 := PlacedPropRuntime.find_by_prop_id(main, pid2)
	var rt2: Node = prop2.get_node_or_null("WasteBinRuntime") if prop2 != null else null
	await tree.create_timer(0.6).timeout
	var drawn2: Dictionary = rt2.call("drawn_counts") if rt2 != null else {}
	# 8 kg / 55 g a can = 145 cans
	_ok(int(drawn2.get("steel_can", 0)) == 145, "8 kg with no ledger = 145 steel cans", str(drawn2))

	# -- clean up -------------------------------------------------------------
	for del_pid in [pid, pid2]:
		if not str(del_pid).is_empty():
			loader.call("delete_prop_by_id", str(del_pid))
	await _frames(tree, 3)
	_ok(model.get_item(gid).is_empty(), "deleting the bin removes its store")

	# ⚠ No bare "FAIL" token here: HarnessReport counts them case-sensitively.
	print("waste-bin: %s" % ("all checks passed" if _fails.is_empty() else "%d failure(s)" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
