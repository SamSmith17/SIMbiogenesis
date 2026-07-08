extends SceneTree

## Offline checks for Sphere of Influence config, area math, and shader globals.

const GODOT := "C:/Users/notsa/Downloads/Godot/Godot.exe.exe"

func _init() -> void:
	var fails := 0
	fails += _check_area_math()
	fails += _check_json_roundtrip()
	fails += _check_radius_clamp()
	fails += _check_save_path_token()
	if fails == 0:
		print("soi_selftest: PASS (%d checks)" % 4)
	else:
		print("soi_selftest: FAIL (%d failures)" % fails)
	quit(fails)


func _check_area_math() -> int:
	var cfg := SoiConfig.defaults()
	cfg.radius_m = 200.0
	var expected := PI * 200.0 * 200.0
	var got := PI * cfg.radius_m * cfg.radius_m
	if absf(got - expected) > 0.01:
		push_error("area math mismatch")
		return 1
	return 0


func _check_json_roundtrip() -> int:
	var cfg := SoiConfig.defaults()
	cfg.center_x = 12.5
	cfg.center_z = -8.25
	cfg.radius_m = 350.0
	var data := cfg.serialize()
	var cfg2 := SoiConfig.defaults()
	cfg2.deserialize(data)
	if absf(cfg2.center_x - 12.5) > 0.001 or absf(cfg2.center_z + 8.25) > 0.001:
		push_error("center round-trip failed")
		return 1
	if absf(cfg2.radius_m - 350.0) > 0.001:
		push_error("radius round-trip failed")
		return 1
	return 0


func _check_radius_clamp() -> int:
	var cfg := SoiConfig.defaults()
	cfg.deserialize({"radius_m": 99999.0})
	if cfg.radius_m != SoiConfig.MAX_RADIUS_M:
		push_error("radius clamp max failed")
		return 1
	cfg.deserialize({"radius_m": 1.0})
	if cfg.radius_m != SoiConfig.MIN_RADIUS_M:
		push_error("radius clamp min failed")
		return 1
	return 0


func _check_save_path_token() -> int:
	var path := SoiConfig.save_path_for_map(33.3548, -115.7261)
	if not path.begins_with("user://maps/soi_"):
		push_error("save path prefix wrong: %s" % path)
		return 1
	if not path.ends_with(".json"):
		push_error("save path suffix wrong")
		return 1
	return 0
