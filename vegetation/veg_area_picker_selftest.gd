extends SceneTree

## Offline deterministic selftest for VegAreaPicker (OSM veg-area crosshair pick).
## Run: Godot.exe.exe --headless --path . --script vegetation/veg_area_picker_selftest.gd

var _checks := 0
var _fails := 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: ", label)


func _init() -> void:
	# Big park (kind "park") with a small lawn (kind "grass_lawn") nested inside it.
	var park := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 100)])
	var lawn := PackedVector2Array([Vector2(40, 40), Vector2(60, 40), Vector2(60, 60), Vector2(40, 60)])
	var polys: Array = [
		{"points": park, "kind": "park", "tags": {}},
		{"points": lawn, "kind": "grass_lawn", "tags": {}},
	]

	# A point inside BOTH → smallest-area (lawn) must win.
	var hit := VegAreaPicker.pick_at_xz(polys, 50.0, 50.0)
	_check(bool(hit.get("valid", false)), "nested point is valid")
	_check(int(hit.get("area_idx", -1)) == 1, "smallest-area (lawn) wins over park")
	_check(str(hit.get("kind", "")) == "grass_lawn", "kind is grass_lawn")
	_check(str(hit.get("kind_label", "")) == "lawn", "kind_label is friendly 'lawn'")

	# A point inside only the park.
	var hit2 := VegAreaPicker.pick_at_xz(polys, 10.0, 10.0)
	_check(int(hit2.get("area_idx", -1)) == 0, "park-only point picks park")
	_check(str(hit2.get("kind_label", "")) == "park", "park kind_label")

	# A point outside everything.
	var miss := VegAreaPicker.pick_at_xz(polys, -50.0, -50.0)
	_check(not bool(miss.get("valid", true)), "outside point is invalid")

	# Tag is the metre-rounded centroid and stable under vertex-order rotation.
	var tag_a := str(VegAreaPicker.area_info(polys, 1).get("tag", ""))
	_check(tag_a == "veg_50_50", "lawn tag is metre-rounded centroid veg_50_50")
	var lawn_rot := PackedVector2Array([Vector2(60, 40), Vector2(60, 60), Vector2(40, 60), Vector2(40, 40)])
	var tag_b := str(VegAreaPicker.area_info([{"points": lawn_rot, "kind": "grass_lawn"}], 0).get("tag", ""))
	_check(tag_a == tag_b, "tag stable under vertex-order rotation")

	# Degenerate / empty inputs never crash and report invalid.
	_check(not bool(VegAreaPicker.pick_at_xz([], 0.0, 0.0).get("valid", true)), "empty polygons invalid")
	_check(not bool(VegAreaPicker.area_info(polys, 9).get("valid", true)), "out-of-range idx invalid")

	if _fails == 0:
		print("VEG AREA PICKER SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		printerr("VEG AREA PICKER SELFTEST FAIL  (%d/%d failed)" % [_fails, _checks])
		quit(1)
