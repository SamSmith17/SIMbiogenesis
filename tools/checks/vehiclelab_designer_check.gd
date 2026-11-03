extends RefCounted

## The living-vehicle designer on a real world (sandbox), with REAL input:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/vehiclelab_designer_check.gd -Label vehiclelab
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/vehiclelab_designer_check.gd -Label vehiclelab_720 -UserArgs @("--window-size=1280x720")
## Every built-in shot in the studio; UiAudit on the open modal and the 720
## fold; a REAL click on the fan tool and on the roof places a fan there; a
## REAL drag slides it along the roof; Delete removes it, Ctrl+Z brings it
## back; solar through the palette reaches the totals; the paint picker and a
## chassis / body swap reach the spec; the cutaway shows the inside; a shipped
## model laid over the parametric one replaces the shell; inside, a REAL click
## on the fridge tool and on the floor places one (the skin comes off), a REAL
## drag slides it, R turns it, Delete / Ctrl+Z, the plan view; then a designed
## vehicle is placed (drivable, its spaces tagged, its power and water node on
## the graph, the shower and galley billed to its own water tank), reopened
## bound to it, its battery changed and applied (the node follows), deleted
## (the node goes).

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("vehiclelab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	main.set("day_time", 13.0)
	main.set("time_scale", 0.0)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(loader != null and loader.has_method("open_vehiclelab"), "the loader hosts the designer")
	if loader == null:
		return {"ok": false, "fails": _fails}
	loader.call("open_vehiclelab")
	await _settle(tree, 20)
	var ui: Control = loader.call("vehiclelab_designer")
	_ok(ui != null and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false, "fails": _fails}
	var vp := main.get_viewport()
	var studio: StudioViewport = ui.call("studio")
	UnitsPref.set_metric(false)
	await _phase4_layout(ui, tree, vp)

	# Every built-in in the studio.
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 10)
		var d: Dictionary = ui.call("design")
		var errs := (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		_ok(errs.is_empty(), "%s solves without an error" % id)
		await RenderingServer.frame_post_draw
		studio.image().save_png("%s/studio_%s.png" % [_dir, id])
	await _shot(main, "modal")
	var audit := UiAudit.run(vp)
	print("vehiclelab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal audits clean")
	var ds: DesignerShell = null
	for c in ui.get_children():
		if c is DesignerShell:
			ds = c
	var canvas := vp.get_visible_rect().size
	if ds != null:
		_ok(ds.is_folded() == (canvas.x < DesignerShell.FOLD_W),
			"the left column is %s on a %d px canvas" % ["folded" if ds.is_folded() else "a column", int(canvas.x)])

	# A REAL click on the fan tool, then on the roof.
	ui.call("load_builtin", "shuttle_bus")
	await _settle(tree, 10)
	var fan_btn := ui.find_child("tool_fan", true, false) as Button
	_ok(fan_btn != null, "the fan tool is in the palette")
	if fan_btn != null:
		await _scroll_into_view(fan_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(fan_btn))
		await _settle(tree, 3)
		_ok(str(ui.call("tool_id")) == "fan", "clicking the tool arms it")
	var n0 := _count(ui)
	var d0: Dictionary = ui.call("design")
	# Clear of the preset's own fan (at the roof's middle) and its solar.
	var roof_pt := Vector3(0.55, VehicleExterior.roof_y(d0, 0.55), float(d0["body"]["z1"]) - 1.0)
	var at := _screen(studio, ui, roof_pt)
	await HarnessInput.mouse_move(vp, at)
	await _settle(tree, 2)
	await HarnessInput.click(vp, at)
	await _settle(tree, 8)
	var d1: Dictionary = ui.call("design")
	var fan := _find_type(d1, "fan", n0)
	_ok(_count(ui) == n0 + 1 and not fan.is_empty() and str(fan["face"]) == "roof",
		"a real click on the roof places a fan there (%d -> %d)" % [n0, _count(ui)])
	_ok(str(ui.call("tool_id")).is_empty(), "the tool disarms after one placement")
	await _shot(main, "fan_placed")
	# A REAL drag slides it toward the rear.
	if not fan.is_empty():
		var fr := VehicleExterior.frame(d1, fan)
		var from := _screen(studio, ui, fr["centre"])
		var to := _screen(studio, ui, (fr["centre"] as Vector3) + Vector3(0.0, 0.0, -1.2))
		var v0 := float(fan["v"])
		await HarnessInput.drag(vp, from, to, 14)
		await _settle(tree, 8)
		var moved := _by_id(ui.call("design"), str(fan["id"]))
		_ok(not moved.is_empty() and float(moved["v"]) < v0 - 0.5,
			"a real drag slides the fan forward along the roof (v %.2f -> %.2f)" % [v0, float(moved.get("v", v0))])
		_ok(str(ui.call("selected")) == str(fan["id"]), "the dragged item is selected")
		await HarnessInput.key(vp, KEY_DELETE)
		await _settle(tree, 6)
		_ok(_by_id(ui.call("design"), str(fan["id"])).is_empty(), "Delete removes it")
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 6)
		_ok(not _by_id(ui.call("design"), str(fan["id"])).is_empty(), "Ctrl+Z brings it back")
	# Solar through the palette.
	var solar_btn := ui.find_child("tool_solar_roof", true, false) as Button
	var w0 := float((ui.call("design") as Dictionary)["exterior_totals"]["solar_w"])
	if solar_btn != null:
		await _scroll_into_view(solar_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(solar_btn))
		await _settle(tree, 3)
		var d2: Dictionary = ui.call("design")
		var spot := _screen(studio, ui, Vector3(0.0, VehicleExterior.roof_y(d2, 0.0), float(d2["body"]["z1"]) - 1.2))
		await HarnessInput.mouse_move(vp, spot)
		await HarnessInput.click(vp, spot)
		await _settle(tree, 8)
	# The palette's item asks for two 400 W modules across; a roof narrower
	# than that keeps whole modules only (Phase 2), so what landed is what
	# fits, and every module kept reaches the totals.
	var d3: Dictionary = ui.call("design")
	var w1 := float(d3["exterior_totals"]["solar_w"])
	var placed := _find_type(d3, "solar", 0)
	var kept := int(placed.get("cols", 0)) * int(placed.get("rows", 0))
	var asked := int(placed.get("cut_cols", placed.get("cols", 0))) * int(placed.get("cut_rows", placed.get("rows", 0)))
	_ok(not placed.is_empty() and kept >= 1 and absf(w1 - w0 - 400.0 * float(kept)) < 0.5,
		"the modules the roof holds reach the totals (%d of %d asked, %.0f -> %.0f W)" % [kept, asked, w0, w1])
	# Paint and chassis / body through the rows.
	var picker := ui.find_child("vl_paint_body", true, false) as ColorPickerButton
	if picker != null:
		picker.color = Color(0.2, 0.5, 0.3)
		picker.color_changed.emit(picker.color)
		await _settle(tree, 12)
	var paint: Array = ((ui.call("spec") as Dictionary)["paint"] as Dictionary)["body"]
	_ok(absf(float(paint[0]) - 0.2) < 0.01 and absf(float(paint[1]) - 0.5) < 0.01, "the body paint reaches the spec")
	var ch_opt := ui.find_child("vl_chassis", true, false) as OptionButton
	if ch_opt != null:
		for i in ch_opt.item_count:
			if str(ch_opt.get_item_metadata(i)) == "chevy_express_3500":
				ch_opt.select(i)
				ch_opt.item_selected.emit(i)
		await _settle(tree, 8)
	_ok(str((ui.call("spec") as Dictionary)["chassis_id"]) == "chevy_express_3500", "a chassis swap keeps the body")
	_ok(str((ui.call("spec") as Dictionary)["body_id"]) == "shuttle_aerotech", "the body stays the shuttle's")
	await _shot(main, "shuttle_on_express")
	ui.call("set_cutaway", true)
	await _settle(tree, 8)
	_ok((ui.call("vehicle_node") as Node3D).get_node_or_null("Shell") == null, "the cutaway hides the shell")
	await RenderingServer.frame_post_draw
	studio.image().save_png("%s/studio_cutaway.png" % _dir)
	ui.call("set_cutaway", false)
	await _settle(tree, 4)
	# A shipped model laid over it.
	var glb := ui.find_child("vl_glb", true, false) as OptionButton
	var have_art := false
	if glb != null:
		for i in glb.item_count:
			if str(glb.get_item_metadata(i)).ends_with("GMC camper van.glb"):
				ui.call("load_builtin", "van")
				await _settle(tree, 6)
				glb.select(i)
				glb.item_selected.emit(i)
				have_art = true
		await _settle(tree, 14)
	if have_art:
		var vn: Node3D = ui.call("vehicle_node")
		_ok(vn.get_node_or_null("GlbOverride") != null and vn.get_node_or_null("Shell") == null,
			"the camper-van art replaces the parametric body")
		await RenderingServer.frame_post_draw
		studio.image().save_png("%s/studio_glb_override.png" % _dir)
	else:
		print("vehiclelab: SKIP the GLB override (no shipped camper-van art in this checkout)")

	# Inside: a REAL click on the fridge tool, then on the floor.
	ui.call("load_builtin", "van")
	await _settle(tree, 8)
	var fridge_btn := ui.find_child("tool_in_fridge", true, false) as Button
	_ok(fridge_btn != null, "the fridge is in the inside palette")
	var in0 := _in_count(ui)
	if fridge_btn != null:
		await _scroll_into_view(fridge_btn, tree)
		await HarnessInput.click(vp, HarnessInput.center_of(fridge_btn))
		await _settle(tree, 6)
		_ok(str(ui.call("tool_id")) == "in_fridge", "clicking an inside tool arms it")
		_ok((ui.call("vehicle_node") as Node3D).get_node_or_null("Shell") == null, "arming it takes the skin off")
		var dv: Dictionary = ui.call("design")
		var house: Dictionary = dv["house"]
		var floor_pt := Vector3(0.0, float(house["floor_y"]), (float(house["z0"]) + float(house["z1"])) * 0.5)
		var fat := _screen(studio, ui, floor_pt)
		await HarnessInput.mouse_move(vp, fat)
		await _settle(tree, 2)
		await HarnessInput.click(vp, fat)
		await _settle(tree, 8)
	_ok(_in_count(ui) == in0 + 1, "a real click on the floor puts a fridge there (%d -> %d)" % [in0, _in_count(ui)])
	var new_id := str(ui.call("selected"))
	_ok(str(ui.call("selected_kind")) == "int" and new_id.begins_with("fridge"), "the new fridge is selected (%s)" % new_id)
	await _shot(main, "inside_fridge_placed")
	# Lay it out from above, as a player does: the plan view.
	ui.call("set_plan_view", true)
	await _settle(tree, 8)
	_ok(studio.pitch > 1.3, "the plan view looks straight down")
	await RenderingServer.frame_post_draw
	studio.image().save_png("%s/studio_plan.png" % _dir)
	var nf := VehicleInterior.element(ui.call("design"), new_id)
	if not nf.is_empty():
		var top := Vector3(float(nf["x"]), float(nf["top_y"]), float(nf["z"]))
		var z0v := float(nf["zc"])
		await HarnessInput.drag(vp, _screen(studio, ui, top), _screen(studio, ui, top + Vector3(0.0, 0.0, 0.8)), 14)
		await _settle(tree, 8)
		var moved_in := VehicleInterior.element(ui.call("design"), new_id)
		_ok(not moved_in.is_empty() and float(moved_in["zc"]) > z0v + 0.3,
			"a real drag slides it back (%.2f -> %.2f m)" % [z0v, float(moved_in.get("zc", z0v))])
		# A square fridge looks the same turned: R is tried on the galley.
		await HarnessInput.key(vp, KEY_DELETE)
		await _settle(tree, 6)
		_ok(VehicleInterior.element(ui.call("design"), new_id).is_empty(), "Delete removes it")
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 6)
		_ok(not VehicleInterior.element(ui.call("design"), new_id).is_empty(), "Ctrl+Z brings it back")
		ui.call("_select", "galley", "int")
		await _settle(tree, 2)
		var g0 := VehicleInterior.element(ui.call("design"), "galley")
		await HarnessInput.key(vp, KEY_R)
		await _settle(tree, 6)
		var g1 := VehicleInterior.element(ui.call("design"), "galley")
		_ok(absf(float(g1["fx"]) - float(g0["fz"])) < 0.01 and absf(float(g1["fz"]) - float(g0["fx"])) < 0.01,
			"R turns the galley a quarter turn")
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 6)
		var info := ui.find_child("vl_in_info", true, false) as Label
		_ok(info != null and not info.text.is_empty(), "the selected piece says what it is (%s)" % (info.text if info != null else ""))
	await _shot(main, "inside_plan")
	var audit_in := UiAudit.run(vp)
	print("vehiclelab: ui audit (inside) — %s" % UiAudit.summary_line(audit_in))
	_ok(int(audit_in.get("errors", 0)) == 0, "the inside card audits clean")
	ui.call("set_plan_view", false)
	await _settle(tree, 4)

	# Place a designed vehicle, reopen it bound, change it, apply.
	ui.call("load_builtin", "shuttle_bus")
	await _settle(tree, 6)
	var spec: Dictionary = VehicleSpec.to_json_safe(ui.call("spec"))
	ui.call("close")
	await _settle(tree, 4)
	_ok(not ui.visible, "Close hides the modal")
	var player := main.get_node_or_null("Player") as Node3D
	var p := player.global_position if player != null else Vector3.ZERO
	var pid := PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": spec, "collision_enabled": true}}, p.x + 9.0, p.z, 0.0)
	await _settle(tree, 10)
	_ok(not pid.is_empty(), "a designed vehicle is placed")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	_ok(prop != null and prop.get_node_or_null("PlacedVehicle") != null, "it is drivable")
	var reg: SpaceRegistry = loader.get("npc_spaces")
	var roles := {}
	if reg != null:
		for sp in reg.spaces:
			var t: Dictionary = (sp as Dictionary).get("target", {})
			if str(t.get("prop_id", "")) == pid:
				roles[str(t.get("role", ""))] = true
	_ok(roles.has("") and roles.has("kitchen"), "its sleep and kitchen spaces are tagged")
	var sgv: Node = PlacedPropService._system_graph_view(main)
	var cid := str(sgv.call("vehicle_system_item_id", pid)) if sgv != null else ""
	_ok(not cid.is_empty(), "its power and water node is on the graph")
	var kinds := _child_types(sgv, cid)
	_ok(kinds.has("battery") and kinds.has("panel") and kinds.has("resource"),
		"the node holds a battery, panels and tanks (%s)" % str(kinds.keys()))
	var water := str(sgv.call("vehicle_tank_id", pid, "water")) if sgv != null else ""
	var billed := 0
	if reg != null:
		for sp in reg.spaces:
			var sd: Dictionary = sp
			var t2: Dictionary = sd.get("target", {})
			if str(t2.get("prop_id", "")) == pid and str(t2.get("role", "")) in ["shower", "kitchen"]:
				if str(sd.get("graph_item_id", "")) == water and not water.is_empty():
					billed += 1
	_ok(billed >= 2, "the shower and the galley draw on its own water tank (%d)" % billed)
	var kwh0 := _battery_kwh(sgv, cid)
	loader.call("open_vehiclelab_for_prop", pid)
	await _settle(tree, 12)
	_ok(bool(ui.call("is_open")), "the designer reopens bound to it")
	var apply := HarnessInput.find_button(ui, "Apply to placed vehicle")
	_ok(apply != null and apply.is_visible_in_tree(), "Apply is offered")
	var trip := ui.find_child("vl_trip_mi", true, false) as SpinBox
	if trip != null:
		trip.value = 420.0
		await _settle(tree, 10)
	ui.call("_select", "battery", "int")
	await _settle(tree, 4)
	var kwh_spin := ui.find_child("vl_in_kwh", true, false) as SpinBox
	_ok(kwh_spin != null, "the battery's card has a capacity")
	if kwh_spin != null:
		kwh_spin.value = kwh0 + 3.0
		await _settle(tree, 12)
	if apply != null:
		await HarnessInput.click(vp, HarnessInput.center_of(apply))
		await _settle(tree, 10)
	var rec := PlacedPropService.get_prop_record(main, pid)
	var rtrip: Dictionary = (rec.get("vehicle_spec", {}) as Dictionary).get("trip", {})
	_ok(absf(float(rtrip.get("one_way_mi", 0.0)) - 420.0) < 0.5, "Apply writes the change onto the placed vehicle")
	var cid2 := str(sgv.call("vehicle_system_item_id", pid)) if sgv != null else ""
	var kwh1 := _battery_kwh(sgv, cid2)
	_ok(not cid2.is_empty() and absf(kwh1 - (kwh0 + 3.0)) < 0.01,
		"the graph node follows the bigger battery (%.1f -> %.1f kWh)" % [kwh0, kwh1])
	await _load_via_lab(main, loader, pid, tree, vp)
	loader.call("delete_prop_by_id", pid)
	await _settle(tree, 4)
	_ok(sgv == null or str(sgv.call("vehicle_system_item_id", pid)).is_empty(), "deleting the vehicle removes its node")
	print("vehiclelab: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


## Transport polish Phase 4: the checks at the top with a badge, factory
## wheelbases, fuel from the chassis, the units toggle (a REAL click).
func _phase4_layout(ui: Control, tree: SceneTree, vp: Viewport) -> void:
	ui.call("load_builtin", "van")
	await _settle(tree, 10)
	var ds: DesignerShell = ui.get("_shell")
	var right: Control = ds.right
	var summary: Control = ui.get("_summary")
	var chassis := ui.find_child("vl_chassis", true, false) as Control
	var first := -1
	var ch_at := -1
	for i in right.get_child_count():
		var c := right.get_child(i)
		if c == summary:
			first = i
		if chassis != null and c.is_ancestor_of(chassis):
			ch_at = i
	_ok(first >= 0 and ch_at > first, "the summary and checks come first in the right column (%d < %d)" % [first, ch_at])
	_ok(ds.badge != null and ds.badge.visible and not ds.badge.text.is_empty(),
		"the header carries the checks badge (%s)" % (ds.badge.text if ds.badge != null else ""))
	var wb := ui.find_child("vl_wheelbase", true, false) as OptionButton
	_ok(wb != null and wb.item_count == 2 and not wb.disabled,
		"the Sprinter offers its factory wheelbases (%d)" % (wb.item_count if wb != null else 0))
	var fuel := ui.find_child("vl_fuel", true, false) as Label
	_ok(fuel != null and fuel.text.begins_with("Diesel"), "the fuel is the chassis' (%s)" % (fuel.text if fuel != null else ""))
	var units := ui.find_child("vl_units", true, false) as CheckBox
	var trip := ui.find_child("vl_trip_mi", true, false) as SpinBox
	if units != null and trip != null:
		trip.value = 100.0
		await _settle(tree, 8)
		_scroll_into_view(units, tree)
		await _settle(tree, 4)
		await HarnessInput.click(vp, HarnessInput.center_of(units))
		await _settle(tree, 8)
		_ok(UnitsPref.metric() and trip.suffix.strip_edges() == "km" and absf(trip.value - 160.9) < 0.2,
			"a real click on the units box shows km (%.1f %s)" % [trip.value, trip.suffix])
		_ok(absf(float(((ui.call("spec") as Dictionary)["trip"] as Dictionary)["one_way_mi"]) - 100.0) < 0.05,
			"the trip stays 100 mi underneath")
		await HarnessInput.click(vp, HarnessInput.center_of(units))
		await _settle(tree, 6)
		_ok(not UnitsPref.metric(), "and a second click puts miles back")
	else:
		_ok(false, "the units box and the trip field exist")
	ds.scroll_top()
	await _settle(tree, 4)


## The Packing Lab loads a kit into the placed vehicle's bay: its host list
## carries the bay and the button reads "Load into …" (a REAL click).
func _load_via_lab(main: Node, loader: Node, pid: String, tree: SceneTree, vp: Viewport) -> void:
	var lab_script: GDScript = load("res://scenes/ui/packing_lab_modal.gd")
	lab_script.call("open_site_cargo", tree)
	await _settle(tree, 12)
	var lab: Node = null
	for c in tree.root.get_children():
		if c.get_script() == lab_script:
			lab = c
	_ok(lab != null and bool(lab.get("visible")), "the Packing Lab opened")
	if lab == null:
		return
	lab.call("_set_container", "vehicle_bay:%s" % pid)
	lab.call("_update_delivery_ui")
	await _settle(tree, 6)
	var btn := HarnessInput.find_button(lab, "Load into", true)
	_ok(btn != null and not btn.disabled, "with the vehicle's bay picked the button reads \"%s\"" % (btn.text if btn != null else "?"))
	if btn != null:
		await HarnessInput.click(vp, HarnessInput.center_of(btn))
		await _settle(tree, 12)
	var stowed := 0
	for r in loader.call("placed_prop_records"):
		if str((r as Dictionary).get("stowed_in", "")) == pid:
			stowed += 1
	_ok(stowed > 0, "a real click loads the kit into the vehicle (%d crates in its bay)" % stowed)
	_ok(bool(lab.get("visible")), "the Lab stays open after loading")
	await _shot(main, "packing_lab_loaded")
	lab.call("close")
	await _settle(tree, 4)
	for r2 in (loader.call("placed_prop_records") as Array).duplicate():
		if str((r2 as Dictionary).get("delivery_id", "")) == pid:
			loader.call("delete_prop_by_id", str((r2 as Dictionary).get("id", "")))


func _scroll_into_view(c: Control, tree: SceneTree) -> void:
	var sc: Node = c.get_parent()
	while sc != null and not (sc is ScrollContainer):
		sc = sc.get_parent()
	if sc is ScrollContainer:
		(sc as ScrollContainer).ensure_control_visible(c)
	for _i in 3:
		await tree.process_frame


## A vehicle-local point as a viewport position for a real click.
func _screen(studio: StudioViewport, ui: Control, local: Vector3) -> Vector2:
	var cpos: Vector2 = ui.call("studio_pos_of", local)
	return studio.container.get_global_rect().position + cpos


func _in_count(ui: Control) -> int:
	return ((ui.call("design") as Dictionary).get("interior", []) as Array).size()


func _child_types(sgv: Node, cid: String) -> Dictionary:
	var out := {}
	if sgv == null or cid.is_empty():
		return out
	var model: GraphModel = sgv.get("model")
	for it in model.get_items_in_scope(str(model.get_item(cid).get("child_scope_id", ""))):
		out[str((it as Dictionary).get("type", ""))] = true
	return out


func _battery_kwh(sgv: Node, cid: String) -> float:
	if sgv == null or cid.is_empty():
		return 0.0
	var model: GraphModel = sgv.get("model")
	for it in model.get_items_in_scope(str(model.get_item(cid).get("child_scope_id", ""))):
		if str((it as Dictionary).get("type", "")) == "battery":
			return float(((it as Dictionary).get("specs", {}) as Dictionary).get("kwh", 0.0))
	return 0.0


func _count(ui: Control) -> int:
	return ((ui.call("design") as Dictionary).get("exterior", []) as Array).size()


func _find_type(d: Dictionary, type: String, skip: int) -> Dictionary:
	var els: Array = d.get("exterior", [])
	for i in range(els.size() - 1, -1, -1):
		if str((els[i] as Dictionary)["type"]) == type:
			return els[i]
	return {}


func _by_id(d: Dictionary, id: String) -> Dictionary:
	for e in d.get("exterior", []):
		if str((e as Dictionary)["id"]) == id:
			return e
	return {}
