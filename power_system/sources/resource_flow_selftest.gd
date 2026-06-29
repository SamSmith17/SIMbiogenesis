extends SceneTree

## Headless self-test for reversible resource timelines + flow conservation.
## Run with:
##   godot --headless --path . --script power_system/sources/resource_flow_selftest.gd

const ResourceTimelineScript := preload("res://core/resource_timeline.gd")
const ResourceKindsScript := preload("res://system_graph/data/resource_kinds.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_step_level()
	_test_reversible_timeline()
	_test_processor_migration()
	_test_resource_migration()
	if _failures == 0:
		print("RESOURCE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("RESOURCE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_step_level() -> void:
	var l0 := ResourceTimelineScript.step_level(0.5, 10.0, 100.0, 1.0)
	_check("step_level forward", absf(l0 - 0.6) < 0.001, "got %.3f" % l0)
	var back := ResourceTimelineScript.unstep_level(l0, 10.0, 100.0, 1.0)
	_check("unstep_level roundtrip", absf(back - 0.5) < 0.001, "got %.3f" % back)


func _test_reversible_timeline() -> void:
	var tl := ResourceTimelineScript.new()
	tl.configure(100.0)
	tl.init_anchor(0.0, 0.5)
	tl.record_step(1.0, 50.0, 50.0, 0.0)
	tl.record_step(2.0, 50.0, 50.0, 0.0)
	var fwd := tl.level_at(2.0)
	_check("timeline forward level > start", fwd > 0.5, "fwd=%.3f" % fwd)
	var rew := tl.seek(0.0)
	_check("timeline rewind to anchor", absf(float(rew.get("level", -1.0)) - 0.5) < 0.02,
		"rew=%.3f" % float(rew.get("level", -1.0)))


func _test_processor_migration() -> void:
	var specs := {"name": "Pump", "watts": 500.0, "output_rate": "50 L/h"}
	ResourceKindsScript.new().migrate_processor_specs(specs)
	_check("processor inputs array", specs.has("inputs"))
	_check("processor outputs array", (specs.get("outputs", []) as Array).size() > 0)


func _test_resource_migration() -> void:
	var specs := {"name": "Water Tank", "capacity": "50 gal", "level": 0.5}
	ResourceKindsScript.new().migrate_resource_specs(specs)
	_check("resource kind", specs.get("resource_kind", "") == "water")
	_check("resource capacity_qty", float(specs.get("capacity_qty", 0.0)) > 0.0)
