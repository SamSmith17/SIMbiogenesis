extends Node

## `--capture=timeline`: the timeline's info row must not MOVE while the clock
## runs. Every centre / right cluster control's global x is recorded while the
## clock is stepped through a whole day (7-minute steps) and through a lunar
## month at noon; any drift above `TOL_PX`, or any change in how many right-
## cluster buttons are folded into the ⋯ menu, FAILs. The clock text changing
## width used to re-centre the whole cluster on every sim minute, which jittered
## the transport, date and sun/moon controls. A single screenshot cannot show
## that — it only exists over time — so this samples it.

const TOL_PX := 0.5

var main: Node = null
var shots_dir := "user://screenshots/timeline"


func run() -> Dictionary:
	var tl := main.get_node_or_null("UILayer/TimelineUI")
	if tl == null:
		print("timeline probe FAIL — no TimelineUI")
		return {"failures": 1}
	var saved_scale = main.get("time_scale")
	var saved_day_time = main.get("day_time")
	var saved_abs := float(main.call("get_absolute_hours")) if main.has_method("get_absolute_hours") else NAN
	main.set("time_scale", 0.0)
	var samples: Array = []   # [{label, xs: {path: x}, folded}]
	# Whole day, 7-minute steps.
	var h := 0.0
	while h < 24.0:
		main.set("day_time", h)
		samples.append(await _sample(tl, "%05.2f h" % h))
		h += 7.0 / 60.0
	# A lunar month at noon (moon label width changes with the phase name).
	if main.has_method("get_absolute_hours") and main.has_method("set_absolute_hours"):
		var base := floorf(float(main.call("get_absolute_hours")) / 24.0) * 24.0 + 12.0
		for d in 30:
			main.call("set_absolute_hours", base + 24.0 * d)
			samples.append(await _sample(tl, "day +%d" % d))
	# Restore the clock.
	if not is_nan(saved_abs) and main.has_method("set_absolute_hours"):
		main.call("set_absolute_hours", saved_abs)
	elif saved_day_time != null:
		main.set("day_time", saved_day_time)
	main.set("time_scale", saved_scale)
	return _judge(samples)


func _sample(tl: Node, label: String) -> Dictionary:
	if tl.has_method("_update_display"):
		tl.call("_update_display")
	await get_tree().process_frame
	await get_tree().process_frame
	var xs := {}
	for cluster_name in ["_center_time_cluster", "_right_cluster"]:
		var c := tl.get(cluster_name) as Control
		if c == null:
			continue
		_collect(c, xs, cluster_name)
	return {"label": label, "xs": xs, "folded": int(tl.get("_right_folded")),
		"clock": str((tl.get("_time_lbl") as Label).text) if tl.get("_time_lbl") != null else ""}


func _collect(node: Node, xs: Dictionary, path: String) -> void:
	for ch in node.get_children():
		var c := ch as Control
		if c == null or not c.is_visible_in_tree():
			continue
		var p := "%s/%s" % [path, c.name]
		if c is Button or c is SpinBox or c is Label or c is PanelContainer:
			xs[p] = c.global_position.x
		_collect(c, xs, p)


func _judge(samples: Array) -> Dictionary:
	var failures := 0
	if samples.is_empty():
		print("timeline probe FAIL — no samples")
		return {"failures": 1}
	var ref: Dictionary = samples[0]
	var worst := 0.0
	var worst_at := ""
	var fold_changes := 0
	for s: Dictionary in samples:
		if int(s["folded"]) != int(ref["folded"]):
			fold_changes += 1
		for k in (ref["xs"] as Dictionary).keys():
			if not (s["xs"] as Dictionary).has(k):
				continue
			var d := absf(float(s["xs"][k]) - float(ref["xs"][k]))
			if d > worst:
				worst = d
				worst_at = "%s @ %s (clock %s)" % [k, s["label"], s["clock"]]
	var ok_drift := worst <= TOL_PX
	var ok_fold := fold_changes == 0
	if not ok_drift:
		failures += 1
	if not ok_fold:
		failures += 1
	print("timeline probe %s — %d samples, %d controls, worst drift %.2f px%s" % [
		"PASS" if ok_drift else "FAIL", samples.size(), (ref["xs"] as Dictionary).size(),
		worst, (" at " + worst_at) if not ok_drift else ""])
	print("timeline probe %s — right-cluster fold count constant (%d change(s))" % [
		"PASS" if ok_fold else "FAIL", fold_changes])
	return {"failures": failures, "worst_px": worst, "fold_changes": fold_changes}
