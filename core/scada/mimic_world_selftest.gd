extends SceneTree

## MimicWorldSource (offline): the true isometric and its inverse, a run's
## corners kept in order, things placed at their world spots, the rest in a
## "Not placed" row, a line with no run dashed.
##   Godot --headless --path . --script core/scada/mimic_world_selftest.gd

const EXPECTED_CHECKS := 12

var _n := 0
var _fails := 0


func _check(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [label, detail])
	else:
		print("  ok  %s" % label)


func _initialize() -> void:
	var iso := MimicWorldSource.Iso.new()
	iso.origin = Vector3(3.0, 1.0, -2.0)
	var worst := 0.0
	for v: Vector3 in [Vector3(0, 0, 0), Vector3(10, 2, -5), Vector3(-7, 0.5, 4), Vector3(3, 1, -2)]:
		var back := iso.from_2d(iso.to_2d(v), v.y)
		worst = maxf(worst, back.distance_to(v))
	_check("the isometric and its inverse agree", worst < 1e-4, "%.6f m" % worst)
	_check("x and z at 30° to the horizontal",
		absf((iso.to_2d(iso.origin + Vector3(1, 0, 0)) - iso.to_2d(iso.origin)).angle() - deg_to_rad(30.0)) < 1e-4)
	_check("up is up the screen", iso.to_2d(iso.origin + Vector3.UP).y < iso.to_2d(iso.origin).y)
	_check("a height drag reads back the height",
		absf(iso.height_at(iso.to_2d(Vector3(4, 2.5, 1)), Vector3(4, 0, 1)) - 2.5) < 1e-4)
	# A schematic with three things and two lines.
	var items := [
		{"id": "t1", "type": "resource", "specs": {"name": "Tank", "resource_kind": "water"}, "x": 0.0, "y": 0.0},
		{"id": "p1", "type": "processor", "specs": {"name": "Filter"}, "x": 200.0, "y": 0.0},
		{"id": "t2", "type": "resource", "specs": {"name": "Day tank", "resource_kind": "water"}, "x": 400.0, "y": 0.0},
	]
	var conns := [
		{"id": "c1", "polarity": "resource", "resource_type": "water", "source_item_id": "t1", "target_item_id": "p1",
			"source_handle_id": "res_out_0", "target_handle_id": "res_in_0"},
		{"id": "c2", "polarity": "resource", "resource_type": "water", "source_item_id": "p1", "target_item_id": "t2",
			"source_handle_id": "res_out_0", "target_handle_id": "res_in_0"},
	]
	var sch := MimicGraphSource.build(items, conns)
	var pos := {"t1": Vector3(0, 0, 0), "p1": Vector3(6, 0, 0)}
	var run := PackedVector3Array([Vector3(0.5, 0.4, 0), Vector3(1.0, 0.4, 0), Vector3(1.0, 0.4, 2.0),
		Vector3(5.0, 0.4, 2.0), Vector3(5.0, 0.4, 0.0), Vector3(5.5, 0.4, 0.0)])
	var doc := MimicWorldSource.build(sch, pos, {"c1": run})
	var by := {}
	for e: Dictionary in doc["elements"]:
		by[str(e["id"])] = e
	var iso2 := MimicWorldSource.iso_of(doc)
	var foot_t1 := iso2.to_2d(Vector3(0, 0, 0))
	var e1: Dictionary = by["t1"]
	_check("a placed thing stands on its world spot",
		absf((e1["pos"] as Vector2).x - foot_t1.x) < 1e-3
		and absf((e1["pos"] as Vector2).y + (e1["size"] as Vector2).y * 0.5 - foot_t1.y) < 1e-3)
	_check("something with no place waits in the Not placed row", bool((by["t2"] as Dictionary).get("unplaced", false)))
	var c1: Dictionary = {}
	var c2: Dictionary = {}
	for p: Dictionary in doc["pipes"]:
		if str(p["id"]) == "c1":
			c1 = p
		elif str(p["id"]) == "c2":
			c2 = p
	_check("the run's line follows its corners in order", (c1["corners"] as PackedVector2Array).size() == run.size()
		and (c1["corners"] as PackedVector2Array)[2].distance_to(iso2.to_2d(run[2])) < 1e-3)
	_check("its bends are the corners between the stubs", (c1["bends"] as PackedVector2Array).size() == run.size() - 4)
	_check("a line with no run is dashed", bool(c2.get("dashed", false)) and bool(c2.get("not_built", false)))
	_check("the doc is As built", bool(doc.get("built", false)))
	_check("far things are drawn first", _depth_sorted(doc["elements"] as Array))
	_check("check count matches EXPECTED_CHECKS", _n + 1 == EXPECTED_CHECKS, "ran %d" % (_n + 1))
	print("MIMIC WORLD SELFTEST %s  (%d checks)" % ["PASS" if _fails == 0 else "FAIL", _n])
	quit(0 if _fails == 0 else 1)


func _depth_sorted(els: Array) -> bool:
	for i: int in range(els.size() - 1):
		if float((els[i] as Dictionary).get("depth", 0.0)) < float((els[i + 1] as Dictionary).get("depth", 0.0)):
			return false
	return true
