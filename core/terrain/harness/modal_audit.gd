class_name ModalAudit
extends Node

## `--capture=modals`: open every modal the player can reach, through its real
## entry point, run UiAudit on it, shoot it, and close it again. The tour only
## passes through a handful of modals; this walks all of them so a sizing or
## overlap regression in any one shows up as a number.
##
## Each entry is {id, open: Callable, close: Callable (optional)}. Openers that
## find nothing to open (no habitat for the routines panel, say) are SKIPPED.
## Output: <shots>/<id>.png + modal_audit.json; one "modalaudit <id>: …" line
## per modal (lower case on purpose — report mode must not trip the harness's
## FAIL tokens) and, with strict, one FAIL line per modal with audit errors.

var main: Node = null
var shots_dir := "user://screenshots/modals"
var strict := false

var _results: Dictionary = {}


func run() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	var tl := main.get_node_or_null("UILayer/TimelineUI")
	var gv := main.get_node_or_null("UILayer/SystemGraphView")
	var help := main.get("help_overlay_ui") as Node
	var picker := main.get_node_or_null("UILayer/LocationPickerUI")
	var entries: Array = [
		{"id": "library", "open": func() -> void: main.call("open_unified_library")},
		{"id": "settings", "open": func() -> void: tl.call("_on_settings_pressed")},
		{"id": "world_panel", "open": func() -> void: tl.call("_on_save_load_pressed")},
		{"id": "record_book", "open": func() -> void: tl.call("_on_record_book_pressed")},
		{"id": "site_report", "open": func() -> void: tl.call("_on_site_report_pressed")},
		{"id": "challenges", "open": func() -> void: tl.call("_on_challenge_pressed")},
		{"id": "multiplayer", "open": func() -> void: tl.call("_on_mp_pressed")},
		{"id": "microclimate", "open": func() -> void: tl.call("_on_microclimate_pressed")},
		{"id": "location_picker", "open": func() -> void: picker.call("show_picker"),
			"close": func() -> void: picker.call("hide_picker")},
		{"id": "help", "open": func() -> void: help.call("open"),
			"close": func() -> void: help.call("close")},
		{"id": "linkage_lab", "open": func() -> void: main.call("open_linkage_lab")},
		{"id": "site_projects", "open": func() -> void: gv.call("open_site_projects")},
		{"id": "work_planner", "open": func() -> void: gv.call("open_work_planner", "", "")},
	]
	entries.append({"id": "scad_store", "open": func() -> void: main.call("open_scad_store")})
	entries.append({"id": "packing_lab", "open": func() -> void:
		load("res://scenes/ui/packing_lab_modal.gd").call("open_site_cargo", get_tree())})
	entries.append({"id": "anim_editor", "open": func() -> void: main.call("open_npc_anim_editor", "")})
	if gv != null and gv.has_method("open_inventory_panel"):
		entries.append({"id": "inventory", "open": func() -> void: gv.call("open_inventory_panel")})
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null:
		entries.append({"id": "veg_tune", "open": func() -> void: loader.call("open_vegetation_preview_editor")})
		if not (loader.get("_buildings_data") as Array).is_empty():
			entries.append({"id": "building_builder", "open": func() -> void: loader.call("open_building_builder", 0)})
	# The conduit style modal (on the first 3D-routable wire) and the
	# connection-port modal (on the first prop-bound node).
	var model: Variant = gv.get("model") if gv != null else null
	if model is GraphModel:
		for c in (model as GraphModel).connections:
			if (model as GraphModel).connection_is_3d_routable(c as Dictionary):
				var cid := str((c as Dictionary).get("id", ""))
				entries.append({"id": "conduit_style", "open": func() -> void: gv.call("open_conduit_style_modal", cid)})
				break
		for it in (model as GraphModel).items:
			if not str(((it as Dictionary).get("specs", {}) as Dictionary).get("bound_prop_id", "")).is_empty() \
					and gv.has_method("open_connection_ports"):
				var iid := str((it as Dictionary).get("id", ""))
				entries.append({"id": "connection_ports", "open": func() -> void: gv.call("open_connection_ports", iid)})
				break
	var hab := _first_habitat(gv)
	if not hab.is_empty():
		entries.append({"id": "npc_routines", "open": func() -> void: gv.call("open_npc_routines", hab)})
	for e in entries:
		await _audit_one(e)
	var errors := 0
	for id in _results:
		errors += int((_results[id] as Dictionary).get("errors", 0))
	var summary := {"modals": _results, "errors": errors,
		"viewport": [int(get_viewport().get_visible_rect().size.x), int(get_viewport().get_visible_rect().size.y)]}
	HarnessReport.write_json("%s/modal_audit.json" % shots_dir, summary)
	return summary


func _audit_one(e: Dictionary) -> void:
	var id := str(e["id"])
	var opener: Callable = e["open"]
	if not opener.is_valid():
		print("modalaudit %s: skipped (no entry point)" % id)
		return
	var before_modal := CursorController.has_blocking_modal()
	opener.call()
	for i in 20:
		await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout
	var opened := CursorController.has_blocking_modal() and not before_modal
	var res := UiAudit.run(get_tree().root.get_viewport())
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [shots_dir, id])
	var errs := int(res.get("errors", 0))
	# A modal hides the first-person HUD (HudLayout.claim_modal); a dock may
	# leave it up, so this is reported, not failed.
	var hud_up := PackedStringArray()
	var hl := HudLayout.get_hud()
	if hl != null:
		var snap: Dictionary = hl.snapshot()
		for pid in ["weather", "scoreboard", "terrain_options", "fun_meter"]:
			if snap.has(pid) and str((snap[pid] as Dictionary).get("state", "")) == "full":
				hud_up.append(pid)
	var lines := PackedStringArray()
	for f in (res.get("findings", []) as Array):
		var fd: Dictionary = f
		if fd.get("severity", "") == "error" and lines.size() < 6:
			lines.append("%s %s %s" % [fd.get("kind", ""), str(fd.get("path", "")).get_file(), str(fd.get("rect", []))])
	_results[id] = {"errors": errs, "warnings": int(res.get("warnings", 0)), "opened_modal": opened,
		"counts": res.get("counts", {}), "first": lines, "hud_up": Array(hud_up)}
	print("modalaudit %s: %s%s%s" % [id, UiAudit.summary_line(res), "" if opened else " (no modal claim seen)",
		"" if hud_up.is_empty() else " · hud up: " + ", ".join(hud_up)])
	for l in lines:
		print("    %s" % l)
	if strict and errs > 0:
		print("modals FAIL %s: %d audit errors" % [id, errs])
	if id == "settings":
		await _walk_settings_pages()
	# Close: the modal's own close, else pop the cursor modal stack.
	var closer: Callable = e.get("close", Callable())
	if closer.is_valid():
		closer.call()
	var guard := 0
	while CursorController.has_blocking_modal() and guard < 6:
		guard += 1
		if not CursorController.pop_top_modal():
			break
		await get_tree().process_frame
	for i in 6:
		await get_tree().process_frame


func _first_habitat(gv: Node) -> String:
	if gv == null:
		return ""
	var model: Variant = gv.get("model")
	if model == null:
		return ""
	for it in GraphNesting.walk_items(model, "root"):
		var item: Dictionary = it
		if str(item.get("type", "")) == "processor" and str((item.get("specs", {}) as Dictionary).get("role", "")) == "habitat":
			return str(item.get("id", ""))
	return ""


## The settings modal is one page at a time behind a sidebar: every page is
## opened, audited and shot (`settings:<page>`), and every nav entry must be on
## screen WITHOUT scrolling the sidebar — the old tab bar hid seven of fifteen
## pages behind scroll arrows and no audit noticed.
func _walk_settings_pages() -> void:
	var tl := main.get_node_or_null("UILayer/TimelineUI")
	var panel: Node = tl.get("_settings_panel") if tl != null else null
	if panel == null or not panel.has_method("page_titles"):
		print("modalaudit settings: FAIL no page list (sidebar missing)")
		return
	var titles: Array = panel.call("page_titles")
	var vis := get_viewport().get_visible_rect()
	var hidden := PackedStringArray()
	for t in titles:
		var b := panel.call("nav_button", t) as Button
		if b == null:
			hidden.append(str(t))
			continue
		var r := b.get_global_rect()
		var clip := _clip_rect(b)
		if not vis.encloses(r) or not clip.encloses(r.grow(-1.0)):
			hidden.append(str(t))
	if hidden.is_empty():
		print("modalaudit settings: PASS all %d pages listed on screen without scrolling" % titles.size())
	else:
		print("modalaudit settings: FAIL %d page(s) off screen or scrolled out: %s" % [hidden.size(), ", ".join(hidden)])
	var start := str(panel.call("current_page"))
	for t in titles:
		panel.call("open_page", t)
		for i in 6:
			await get_tree().process_frame
		var res := UiAudit.run(get_tree().root.get_viewport())
		var id := "settings:%s" % str(t)
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("%s/settings_%s.png" % [shots_dir, str(t).to_lower().replace(" ", "_").replace("&", "and")])
		var errs := int(res.get("errors", 0))
		_results[id] = {"errors": errs, "warnings": int(res.get("warnings", 0)), "counts": res.get("counts", {})}
		print("modalaudit %s: %s" % [id, UiAudit.summary_line(res)])
		if strict and errs > 0:
			print("modals FAIL %s: %d audit errors" % [id, errs])
	if not start.is_empty():
		panel.call("open_page", start)


## The visible rect of the nearest scrolling ancestor (or the viewport).
func _clip_rect(c: Control) -> Rect2:
	var n := c.get_parent()
	while n != null:
		if n is ScrollContainer:
			return (n as Control).get_global_rect()
		n = n.get_parent()
	return get_viewport().get_visible_rect()
