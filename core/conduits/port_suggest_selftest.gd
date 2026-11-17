extends SceneTree

## PortSuggest (offline): ports on the box's faces by what they carry, spread
## apart, pointing out; a picked normal turned outward and snapped.
##   Godot --headless --path . --script core/conduits/port_suggest_selftest.gd

const EXPECTED_CHECKS := 11

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
	var box := AABB(Vector3(-1.0, 0.0, -0.5), Vector3(2.0, 1.5, 1.0))
	var handles := [
		{"id": "w_in", "polarity": "resource", "resource_kind": "water", "direction": "in"},
		{"id": "w_out", "polarity": "resource", "resource_kind": "water", "direction": "out"},
		{"id": "ac1", "polarity": "ac", "direction": "in"},
		{"id": "ac2", "polarity": "load", "direction": "out"},
		{"id": "net", "polarity": "data"},
		{"id": "gas", "polarity": "resource", "resource_kind": "woodgas", "direction": "out"},
	]
	var s := PortSuggest.suggest(handles, box)
	var by := {}
	for e: Dictionary in s:
		by[str(e["handle_id"])] = e
	_check("every port placed", by.size() == handles.size(), str(by.keys()))
	var on_face := true
	for e: Dictionary in s:
		var p: Vector3 = e["pos"]
		var nn: Vector3 = e["normal"]
		if not box.grow(0.001).has_point(p) or box.grow(-0.001).has_point(p):
			on_face = false
		if box.grow(-0.01).has_point(p + nn * 0.05):
			on_face = false
	_check("all on the box's surface, pointing out", on_face)
	_check("water in and out on opposite sides", (by["w_in"]["normal"] as Vector3) == -(by["w_out"]["normal"] as Vector3))
	_check("water low", (by["w_in"]["pos"] as Vector3).y < box.position.y + box.size.y * 0.3)
	_check("power on one face, side by side",
		(by["ac1"]["normal"] as Vector3) == (by["ac2"]["normal"] as Vector3)
		and (by["ac1"]["pos"] as Vector3).distance_to(by["ac2"]["pos"] as Vector3) > 0.3)
	_check("data high on the back", (by["net"]["pos"] as Vector3).y > box.position.y + box.size.y * 0.7)
	_check("gas on top", (by["gas"]["normal"] as Vector3) == Vector3.UP)
	# Normals.
	var inward := PortSuggest.clean_normal(Vector3(-1, 0, 0), Vector3(1.0, 0.7, 0.0), box, false)
	_check("an inside-out normal is turned outward", inward == Vector3.RIGHT, str(inward))
	var near := PortSuggest.clean_normal(Vector3(1.0, 0.1, 0.05).normalized(), Vector3(1.0, 0.7, 0.0), box, false)
	_check("a nearly square normal snaps to its axis", near == Vector3.RIGHT, str(near))
	var slant := Vector3(1.0, 1.0, 0.0).normalized()
	_check("a slanted one stays unless snapped", PortSuggest.clean_normal(slant, Vector3(1.0, 1.5, 0.0), box, false)
		.is_equal_approx(slant) and PortSuggest.clean_normal(slant, Vector3(1.0, 1.5, 0.0), box, true) in [Vector3.RIGHT, Vector3.UP])
	_check("check count matches EXPECTED_CHECKS", _n + 1 == EXPECTED_CHECKS, "ran %d" % (_n + 1))
	print("PORT SUGGEST SELFTEST %s  (%d checks)" % ["PASS" if _fails == 0 else "FAIL", _n])
	quit(0 if _fails == 0 else 1)
