extends RefCounted

## The ESP board designer on a real world (sandbox; writes only the sandbox's
## user://esplab_designs):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/esplab_designer_check.gd -Label esplab
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/esplab_designer_check.gd -Label esplab_720 -UserArgs @("--window-size=1280x720")
## Opens it through Main, loads every built-in (no wiring errors, wires
## drawn, a shot each), audits the open modal (and the 720 fold), then with
## REAL input: Empty board, five parts from the palette (BME280 + OLED share
## one I²C bus), a part's pin dragged onto a free board pin (wired by hand),
## a double-click on that wire (given back), a card dragged (layout only, no
## re-solve), Delete + Ctrl+Z, the YAML tab, Copy YAML, Export files, a
## board switch, Esc closing it.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("esplab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _reveal(c: Control, tree: SceneTree) -> void:
	var n: Node = c.get_parent()
	while n != null and not (n is ScrollContainer):
		n = n.get_parent()
	if n != null:
		(n as ScrollContainer).ensure_control_visible(c)
	await tree.process_frame
	await tree.process_frame


func _find(ui: Node, name: String) -> Control:
	return ui.find_child(name, true, false) as Control


## A control-local diagram point -> viewport coordinates.
func _g(diagram: Control, local: Vector2) -> Vector2:
	return diagram.get_global_transform() * local


func _shell(ui: Node) -> DesignerShell:
	for c in ui.get_children():
		if c is DesignerShell:
			return c
	return null


func _click_left(ui: Control, name: String, tree: SceneTree, vp: Viewport) -> bool:
	var ds := _shell(ui)
	if ds != null and ds.is_folded() and not ds.left_popup_shown():
		ds.show_left_popup()
		await _settle(tree, 3)
	var b := _find(ds if ds != null else ui, name)
	if b == null:
		# A folded left column lives in the flyout, outside the shell's tree.
		b = _find(ui.get_tree().root, name)
	if b == null:
		return false
	await _reveal(b, tree)
	await HarnessInput.click(vp, HarnessInput.center_of(b))
	await _settle(tree, 3)
	return true


func _parts(ui: Control) -> int:
	return ((ui.call("spec") as Dictionary)["parts"] as Array).size()


func _iid_of(ui: Control, part: String) -> String:
	for p in (ui.call("spec") as Dictionary)["parts"]:
		if str(p["part"]) == part:
			return str(p["iid"])
	return ""


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	_ok(main.has_method("open_esplab"), "Main hosts the designer")
	var ui: Control = main.call("open_esplab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false}
	var vp := main.get_viewport()
	var diagram: Control = ui.call("diagram")

	# Every built-in.
	for b in EspPresets.builtins():
		var id := str(b["id"])
		ui.call("load_builtin", id)
		await _settle(tree, 6)
		var d: Dictionary = ui.call("design")
		var errs := (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
		_ok(errs.is_empty(), "%s wires without an error %s" % [id, str(errs)])
		_ok(int(diagram.call("wire_count")) >= 2 * (d["spec"]["parts"] as Array).size(), "%s draws its wires (%d)" % [id, int(diagram.call("wire_count"))])
		await _shot(main, "builtin_%s" % id)
	var audit := UiAudit.run(vp)
	print("esplab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal audits clean")
	var ds := _shell(ui)
	var canvas := vp.get_visible_rect().size
	if ds != null:
		_ok(ds.is_folded() == (canvas.x < DesignerShell.FOLD_W),
			"the left column is %s on a %d px canvas" % ["folded" if ds.is_folded() else "a column", int(canvas.x)])

	# An empty board, then five parts from the palette with real clicks.
	_ok(await _click_left(ui, "new_blank", tree, vp), "Empty board button found")
	_ok(_parts(ui) == 0, "the board is empty")
	for pid in ["bme280", "ssd1306", "ds18b20", "hcsr04", "relay_1ch"]:
		_ok(await _click_left(ui, "add_%s" % pid, tree, vp), "palette button for %s" % pid)
	if ds != null and ds.left_popup_shown():
		ds.hide_left_popup()
	await _settle(tree, 4)
	diagram.call("fit")
	await _settle(tree, 3)
	_ok(_parts(ui) == 5, "five parts added by clicking the palette (%d)" % _parts(ui))
	var d2: Dictionary = ui.call("design")
	var i2c: Array = d2["wire"]["buses"]["i2c"]
	_ok(i2c.size() == 1 and (i2c[0]["members"] as Array).size() == 2, "BME280 and OLED share one I²C bus")
	_ok(str(ui.call("yaml_text")).find("platform: ultrasonic") >= 0, "the YAML has the HC-SR04")
	# The twin reads the world at the site, live (a refresh a second).
	await tree.create_timer(1.3).timeout
	var live: Dictionary = ui.call("live_readings")
	var node_name := str(d2["node"])
	var lt: Dictionary = live.get("sensor.%s_bme280_temperature" % EspEntityNames.ha_slug(str(d2["friendly"])).trim_suffix("_"), {})
	if lt.is_empty():
		for k in live:
			if str(k).ends_with("_bme280_temperature"):
				lt = live[k]
	var ws := tree.root.get_node_or_null("WeatherService")
	var site_t := NAN
	if ws != null:
		var dd: Dictionary = CelestialClock.new().abs_hours_to_date(float(main.call("get_absolute_hours")))
		site_t = float(ws.call("temperature_c", int(dd["month"]), int(dd["day"]), float(dd["day_time"])))
	print("esplab: twin BME280 %s, the site's weather %.1f °C; pressure %s; node %s" % [
		str(lt.get("text", "?")), site_t, str(live.get("sensor.new_board_bme280_pressure", {}).get("text", "?")), node_name])
	_ok(bool(lt.get("available", false)), "the twin's BME280 temperature is available (%s)" % str(lt.get("text", "")))
	if bool(lt.get("available", false)) and not is_nan(site_t):
		_ok(absf(float(lt["value"]) - site_t) < 1.5, "it reads the site's air temperature within the part's accuracy (%.2f vs %.2f)" % [float(lt["value"]), site_t])
	var pr: Dictionary = live.get("sensor.new_board_bme280_pressure", {})
	_ok(bool(pr.get("available", false)) and float(pr["value"]) > 800.0 and float(pr["value"]) < 1100.0, "pressure in hPa (%s)" % str(pr.get("text", "")))
	var hc: Dictionary = live.get("sensor.new_board_hc_sr04_distance", {})
	_ok(bool(hc.get("available", false)), "the ultrasonic reads its bench distance (%s)" % str(hc.get("text", "")))
	var lbl := _find(ui, "val_sensor_new_board_bme280_temperature") as Label
	_ok(lbl != null and lbl.text == str(lt.get("text", "-")), "the entity list shows the reading (%s)" % (lbl.text if lbl != null else "no label"))
	var card_lines: Dictionary = diagram.get("_readings")
	var bl: PackedStringArray = card_lines.get(_iid_of(ui, "bme280"), PackedStringArray())
	_ok(bl.size() == 3 and bl[0].find("°C") > 0, "the BME280 card shows its three readings (%s)" % str(bl))
	await _shot(main, "five_parts")

	# Wire the relay by hand: drag its IN pin onto a free board pin.
	var relay := _iid_of(ui, "relay_1ch")
	var board: Dictionary = d2["board"]
	var used: Dictionary = d2["wire"]["used"]
	var target := -1
	for p in EspBoards.pins(board):
		var g := int(p["gpio"])
		if g >= 0 and not used.has(g) and EspBoards.pin_state(board, p) == "free":
			target = g
			break
	_ok(target >= 0, "a free board pin to wire to (GPIO%d)" % target)
	var a := _g(diagram, diagram.call("part_pin_local", relay, "IN"))
	var b := _g(diagram, diagram.call("board_pin_local", target))
	await HarnessInput.drag(vp, a, b, 16)
	await _settle(tree, 4)
	var locks: Dictionary = (ui.call("spec") as Dictionary)["locks"]
	_ok(int(locks.get("%s:IN" % relay, -1)) == target, "dragging the pin wired it by hand (%s)" % str(locks))
	var got: Variant = ((ui.call("design") as Dictionary)["wire"]["assign"][relay] as Dictionary).get("IN", null)
	_ok(got is int and int(got) == target, "the relay's IN is on GPIO%d" % target)
	await _shot(main, "wired_by_hand")
	# Double-click the wire: the tool takes it back.
	var mid: Vector2 = diagram.call("wire_mid_local", relay, "IN")
	await HarnessInput.click(vp, _g(diagram, mid), true)
	await _settle(tree, 4)
	locks = (ui.call("spec") as Dictionary)["locks"]
	_ok(not locks.has("%s:IN" % relay), "double-clicking the wire gave it back")

	# Drag a card: layout only.
	var bme := _iid_of(ui, "bme280")
	var key_before := EspSpec.key_of(ui.call("spec"))
	var c0: Vector2 = diagram.call("card_local", bme)
	await HarnessInput.drag(vp, _g(diagram, c0), _g(diagram, c0 + Vector2(40, 70)), 10)
	await _settle(tree, 3)
	var lay: Dictionary = (ui.call("spec") as Dictionary).get("layout", {})
	_ok(lay.has(bme), "dragging a card moved it")
	_ok(EspSpec.key_of(ui.call("spec")) == key_before, "moving a card does not change the design")
	_ok(str((ui.call("selected") as Dictionary).get("iid", "")) == bme, "the dragged card is selected")

	# Delete + Ctrl+Z.
	await HarnessInput.key(vp, KEY_DELETE)
	await _settle(tree, 3)
	_ok(_parts(ui) == 4 and _iid_of(ui, "bme280") == "", "Delete removed the selected part")
	await HarnessInput.key(vp, KEY_Z, true)
	await _settle(tree, 3)
	_ok(_parts(ui) == 5 and _iid_of(ui, "bme280") != "", "Ctrl+Z brought it back")

	# The checks: the HC-SR04's 5 V echo is a warning, shown in the badge.
	var d3: Dictionary = ui.call("design")
	_ok(EspDesign.count_level(d3, "warn") >= 1, "the HC-SR04 echo warning is there")
	if ds != null and ds.badge != null:
		_ok(ds.badge.visible and ds.badge.text.find("warning") >= 0, "the header badge counts warnings (%s)" % ds.badge.text)

	# The YAML tab and Copy YAML.
	var tab := _find(ui, "tab_yaml")
	await HarnessInput.click(vp, HarnessInput.center_of(tab))
	await _settle(tree, 3)
	var yv := _find(ui, "YamlView") as CodeEdit
	_ok(yv != null and yv.visible and yv.text == str(ui.call("yaml_text")), "the YAML tab shows the design's YAML")
	await _shot(main, "yaml_tab")
	var copy := _find(ui, "copy_yaml")
	await HarnessInput.click(vp, HarnessInput.center_of(copy))
	await _settle(tree, 3)
	# Windows hands text back with CRLF line ends.
	_ok(DisplayServer.clipboard_get().replace("\r\n", "\n") == str(ui.call("yaml_text")), "Copy YAML put it on the clipboard")
	var tab2 := _find(ui, "tab_diagram")
	await HarnessInput.click(vp, HarnessInput.center_of(tab2))
	await _settle(tree, 3)

	# Export files.
	var exp := HarnessInput.find_button(ui, "Export files")
	await HarnessInput.click(vp, HarnessInput.center_of(exp))
	await _settle(tree, 12)
	var dir := str(ui.call("export_dir"))
	var node := str((ui.call("design") as Dictionary)["node"])
	for f in [node + ".yaml", "secrets.yaml", "wiring.png", "design.json"]:
		_ok(FileAccess.file_exists(dir.path_join(f)), "exported %s" % f)
	var img := Image.load_from_file(ProjectSettings.globalize_path(dir.path_join("wiring.png")))
	_ok(img != null and img.get_width() > 200 and img.get_height() > 200, "wiring.png is the diagram (%s)" % (str(img.get_size()) if img != null else "none"))
	_ok(FileAccess.get_file_as_string(dir.path_join(node + ".yaml")) == str(ui.call("yaml_text")), "the exported YAML is the design's")
	_ok(FileAccess.get_file_as_string(dir.path_join("secrets.yaml")).find("api_encryption_key") >= 0, "the secrets template")

	# Switch board: the same parts on a Pico W.
	ui.call("set_board", "pico_w")
	await _settle(tree, 4)
	var d4: Dictionary = ui.call("design")
	_ok(str(d4["spec"]["board"]) == "pico_w" and EspDesign.count_level(d4, "error") == 0, "the same parts wire onto a Pico W")
	_ok(str(ui.call("yaml_text")).find("rp2:") >= 0, "the YAML follows the board")
	diagram.call("fit")
	await _shot(main, "pico")
	var audit2 := UiAudit.run(vp)
	_ok(int(audit2.get("errors", 0)) == 0, "audits clean after the edits (%s)" % UiAudit.summary_line(audit2))

	# Esc closes it.
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 4)
	_ok(not bool(ui.call("is_open")), "Esc closed the designer")
	print("esplab: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "failures": _fails}
