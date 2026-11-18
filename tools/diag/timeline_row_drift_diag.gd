extends RefCounted

## Sandbox: why the timeline's centre cluster moves. Steps the clock through a
## day in 7-minute steps (as --capture=timeline does) and prints, whenever the
## centre cluster's x changes: the row width, both side clusters' widths, the
## centre's width, which rule placed it (centred / slid into the gap / hugging
## the left), the needs chips' text and widths and every centre child's
## minimum width.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/timeline_row_drift_diag.gd -UserArgs @("--window-size=1280x720")

func _row(tl: Node) -> Dictionary:
	var row: Control = tl.get("_info_row")
	var left: Control = tl.get("_left_cluster")
	var right: Control = tl.get("_right_cluster")
	var centre: Control = tl.get("_center_time_cluster")
	var row_w := row.size.x
	var lo := left.position.x + left.size.x + float(tl.get("CENTER_CLUSTER_GAP"))
	var hi := right.position.x - float(tl.get("CENTER_CLUSTER_GAP"))
	var cw := centre.size.x
	var centred := (row_w - cw) * 0.5
	var rule := "centred"
	if centred > hi - cw:
		rule = "slid left of the right cluster"
	if minf(centred, hi - cw) < lo:
		rule = "pushed by the left cluster"
	var chips := []
	var needs: Dictionary = tl.get("_needs_chips")
	for k in needs.keys():
		var b: Button = needs[k]
		chips.append("%s '%s' %.1f" % [k, b.text, b.get_combined_minimum_size().x])
	var kids := []
	for ch in centre.get_children():
		var c := ch as Control
		if c != null and c.visible:
			kids.append("%s %.1f" % [c.name, c.get_combined_minimum_size().x])
	return {"x": centre.position.x, "row_w": row_w, "left_w": left.size.x, "right_w": right.size.x,
		"lo": lo, "hi": hi, "cw": cw, "rule": rule, "chips": chips, "kids": kids,
		"clock": str((tl.get("_time_lbl") as Label).text)}


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 200:
		await tree.process_frame
	var tl: Node = main.get_node_or_null("UILayer/TimelineUI")
	if tl == null:
		return {"ok": false, "why": "no TimelineUI"}
	main.set("time_scale", 0.0)
	var last: Dictionary = {}
	var h := 0.0
	var changes := 0
	while h < 24.0:
		main.set("day_time", h)
		tl.call("_update_display")
		await tree.process_frame
		await tree.process_frame
		var r := _row(tl)
		if last.is_empty() or absf(float(r["x"]) - float(last["x"])) > 0.01:
			changes += 1
			print("rowdrift: %05.2f h (%s) centre x %.2f [%s] row %.1f left %.1f right %.1f lo %.1f hi %.1f cw %.1f" % [
				h, r["clock"], r["x"], r["rule"], r["row_w"], r["left_w"], r["right_w"], r["lo"], r["hi"], r["cw"]])
			print("rowdrift:   chips %s" % str(r["chips"]))
			print("rowdrift:   centre kids %s" % str(r["kids"]))
		last = r
		h += 7.0 / 60.0
	print("rowdrift: %d change(s) of the centre's x over the day" % changes)
	return {"ok": true}
