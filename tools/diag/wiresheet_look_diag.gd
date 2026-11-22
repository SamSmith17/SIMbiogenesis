extends SceneTree

## The wiring-diagram page on a sample chain (WINDOWED; APPDATA at a scratch
## folder): the bootcamp panel + MPPT + battery with a fuse, a switch and a
## bus in the battery leads, a shunt and a monitor on data, drawn by the
## real page view and saved as a PNG beside the SVG the export writes.
##   Godot --path . --windowed --resolution 1600x900 --script tools/diag/wiresheet_look_diag.gd -- --out=<png> [--chain=victron|trainer] [--data]

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const VIEW := preload("res://scenes/ui/wiresheet_view.gd")

var _out := "user://wiresheet_look.png"
var _chain_kind := "victron"
var _data := true


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--chain="):
			_chain_kind = a.substr(8)
		elif a == "--nodata":
			_data = false
	_run.call_deferred()


func _run() -> void:
	var m := _chain()
	var view := Control.new()
	view.set_script(VIEW)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(view)
	await process_frame
	var lay := WireSheet.layout(m, "ctl", {"show_data": _data})
	view.call("set_layout", lay)
	view.call("fit")
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(_out)
	var svg_path := _out.get_basename() + ".svg"
	var svg_text := WireSheet.svg(lay)
	var f := FileAccess.open(svg_path, FileAccess.WRITE)
	if f != null:
		f.store_string(svg_text)
	var svg_img := Image.new()
	if svg_img.load_svg_from_string(svg_text, 2.5) == OK:
		svg_img.save_png(_out.get_basename() + "_svg.png")
	print("wiresheet look: %d devices, %d conductors, %d checks" % [(lay["devices"] as Array).size(),
		(lay["conductors"] as Array).size(), (lay["checks"] as Array).size()])
	for d in (lay["devices"] as Array):
		print("  device %-10s %-12s %s" % [d["id"], d["kind"], str(d["box"])])
	for c in (lay["conductors"] as Array):
		print("  wire %s -> %s %s %s %.1f m lane %d %s" % [c["a"], c["b"], c["polarity"], c["gauge"], float(c["length_m"]), int(c.get("lane", -1)), str(c["pts"])])
	print("  lanes ", str(lay.get("lanes", [])), " trough_top ", lay.get("trough_top", 0.0))
	for d in (lay["devices"] as Array):
		for p in (d["ports"] as Array):
			print("    port %s.%s %s dir %s via %s" % [d["id"], p["handle"], str(p["pos"]), str(p["dir"]), str(p.get("via", []))])
	print("wiresheet look sheet: ", ProjectSettings.globalize_path(_out))
	quit(0)


func _chain() -> GraphModel:
	var m: GraphModel = GraphModelScript.new()
	var n := 3
	for i in n:
		_add(m, "pnl%d" % i, "Trainer 300W")
	for i in n - 1:
		_wire(m, "pnl%d" % i, "negative", "pnl%d" % (i + 1), "positive", "negative")
	if _chain_kind == "victron":
		_add(m, "ctl", "Victron 150/35", "controller")
	else:
		_add(m, "ctl", "Trainer MPPT 150/30")
	_add(m, "bat", "12V 100Ah AGM")
	_wire(m, "pnl0", "positive", "ctl", "pvPositive", "positive")
	_wire(m, "pnl%d" % (n - 1), "negative", "ctl", "pvNegative", "negative")
	_wire(m, "ctl", "batteryPositive", "bat", "positive", "positive")
	_wire(m, "ctl", "batteryNegative", "bat", "negative", "negative")
	var pos := _conn(m, "ctl", "batteryPositive")
	var fuse := WireSheet.insert(m, pos, "fuse")
	var after := _conn(m, fuse, "output")
	WireSheet.insert(m, after, "switch")
	var neg := _conn(m, "ctl", "batteryNegative")
	var shunt := WireSheet.insert(m, neg, "shunt")
	if _data:
		m.add_item({"id": "mon", "type": "appliance", "label": "Battery monitor", "x": 0.0, "y": 0.0,
			"width": 120.0, "height": 60.0, "scope_id": "root", "specs": {"name": "BMV-712"}})
		_wire(m, shunt, "data", "mon", "data", "data")
		_wire(m, "ctl", "data", "mon", "data", "data")
	return m


func _add(m: GraphModel, id: String, label: String, kind: String = "") -> void:
	var p := TutorialCatalog.find_preset(label)
	if p.is_empty() and kind == "controller":
		for c in ComponentPresets.CONTROLLERS:
			if str(c.get("label", "")) == label:
				p = c
	m.add_item({
		"id": id, "type": str(p["type"]), "label": label,
		"x": 0.0, "y": 0.0, "width": float(p.get("width", 120)), "height": float(p.get("height", 60)),
		"scope_id": "root", "specs": (p["specs"] as Dictionary).duplicate(true),
	})


func _wire(m: GraphModel, a: String, ha: String, b: String, hb: String, pol: String) -> void:
	m.add_connection({
		"scope_id": "root", "polarity": pol,
		"source_item_id": a, "source_handle_id": ha,
		"target_item_id": b, "target_handle_id": hb,
	})


func _conn(m: GraphModel, a: String, ha: String) -> String:
	for c in m.connections:
		var cd: Dictionary = c
		if str(cd.get("source_item_id", "")) == a and str(cd.get("source_handle_id", "")) == ha:
			return str(cd.get("id", ""))
	return ""
