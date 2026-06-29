extends SceneTree

## Offline checks for placed prop persistence + building picker + catalog.

const CHECKS := [
	"coord_token_path",
	"layer_json_roundtrip",
	"building_picker",
	"catalog_shipped",
]


func _init() -> void:
	var fails := 0
	for name in CHECKS:
		var fn := Callable(self, "_check_%s" % name)
		if not fn.is_valid():
			push_error("placed_prop_selftest: missing %s" % name)
			fails += 1
			continue
		if not fn.call():
			push_error("placed_prop_selftest FAIL: %s" % name)
			fails += 1
		else:
			print("placed_prop_selftest OK: %s" % name)
	if fails > 0:
		push_error("placed_prop_selftest: %d failed" % fails)
		quit(1)
	else:
		print("placed_prop_selftest: all %d checks passed" % CHECKS.size())
		quit(0)


func _check_coord_token_path() -> bool:
	var lat := 37.7749
	var lon := -122.4194
	var layer := PlacedPropLayer.create_empty()
	var path := layer.save_path_for_map(lat, lon)
	return path.contains("placed_props_") and path.contains("n122") and path.contains("37p7749")


func _check_layer_json_roundtrip() -> bool:
	var layer := PlacedPropLayer.create_empty()
	var id := layer.add_free_prop("pine_1", 10.0, 5.0, 20.0, 45.0, 0.0, 0.0, 1.2, 4.5)
	if id.is_empty():
		return false
	layer.add_osm_prop(3, "shiftpod", 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.8, 2.0)
	var data := layer.serialize()
	var layer2 := PlacedPropLayer.create_empty()
	layer2.deserialize(data)
	if layer2.props.size() != 2:
		return false
	var replaced: Array[int] = layer2.get_replaced_building_indices()
	return replaced.size() == 1 and replaced[0] == 3


func _check_building_picker() -> bool:
	var poly := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(10.0, 10.0), Vector2(0.0, 10.0),
	])
	var buildings: Array = [{"idx": 7, "points": poly, "height_m": 8.0}]
	var inside := BuildingPicker.pick_at_xz(buildings, 5.0, 5.0)
	var outside := BuildingPicker.pick_at_xz(buildings, 50.0, 50.0)
	return bool(inside.get("valid", false)) and int(inside.get("building_idx", -1)) == 7 and not bool(outside.get("valid", false))


func _check_catalog_shipped() -> bool:
	var models := ModelCatalog.all_models()
	if models.is_empty():
		return false
	var pine := ModelCatalog.find("pine_1")
	return not pine.is_empty() and str(pine.get("path", "")).ends_with(".glb")
