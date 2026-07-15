extends SceneTree
## Offline checks for GraphModelPreviewService cache keys + camera defaults.
## Run:
##   Godot.exe.exe --headless --path . --script system_graph/graph_model_preview_selftest.gd

const PreviewScript := preload("res://system_graph/graph_model_preview_service.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_cache_keys()
	_test_camera_defaults()
	_test_vawt_catalog()
	if _failures == 0:
		print("GRAPH MODEL PREVIEW SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("GRAPH MODEL PREVIEW SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_cache_keys() -> void:
	var k1 := PreviewScript.cache_key_for("vawt", 0.0, 12.0, 1.9)
	var k2 := PreviewScript.cache_key_for("vawt", 0.0, 12.0, 1.9)
	var k3 := PreviewScript.cache_key_for("vawt", 35.0, 12.0, 1.9)
	_check("cache key stable", k1 == k2 and not k1.is_empty())
	_check("cache key changes with yaw", k1 != k3)
	var specs := {"model_id": "vawt"}
	var k4 := PreviewScript.cache_key_from_specs(specs)
	_check("cache key from specs defaults", k4 == k1, "got %s vs %s" % [k4, k1])
	_check("empty model_id → empty key", PreviewScript.cache_key_from_specs({}).is_empty())


func _test_camera_defaults() -> void:
	var cam := PreviewScript.camera_from_specs({})
	_check("default yaw head-on", absf(float(cam.yaw) - PreviewScript.DEFAULT_YAW_DEG) < 0.01)
	_check("default pitch slight elevate", absf(float(cam.pitch) - PreviewScript.DEFAULT_PITCH_DEG) < 0.01)
	_check("default dist", absf(float(cam.dist) - PreviewScript.DEFAULT_DIST_MULT) < 0.01)
	var cam2 := PreviewScript.camera_from_specs({
		"card_preview_yaw_deg": 45.0,
		"card_preview_pitch_deg": 20.0,
		"card_preview_dist_mult": 2.5,
	})
	_check("custom yaw", absf(float(cam2.yaw) - 45.0) < 0.01)
	_check("custom pitch", absf(float(cam2.pitch) - 20.0) < 0.01)


func _test_vawt_catalog() -> void:
	var entry := ModelCatalog.find("vawt")
	_check("vawt in catalog", not entry.is_empty())
	_check("vawt path set", not str(entry.get("path", "")).is_empty())
	var metrics := ModelCatalog.mesh_metrics("vawt")
	_check("vawt metrics height", float(metrics.get("unit_height", 0.0)) > 0.5,
		"h=%.3f" % float(metrics.get("unit_height", 0.0)))
