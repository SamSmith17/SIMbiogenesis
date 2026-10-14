extends SceneTree

## Offline selftest for the harness registry + report (core/terrain/harness/).
##   Godot --headless --path . --script core/terrain/harness/harness_registry_selftest.gd
## Pins: every registered capture names a real harness method, a real default
## WORLD (Mount Vernon / Walton — never the built-in SOAK / Mars scenes) and a
## watchdog budget; world aliases pick the NEWEST matching world and never a
## scratch copy; the report's FAIL / PASS classification (case-sensitive:
## "0 failure(s)" is a pass) and its result line.
## Carries EXPECTED_CHECKS: a runtime error aborts a test function while the
## suite would still print PASS.

const EXPECTED_CHECKS := 35
const HARNESS_PATH := "res://core/terrain/playtest_harness.gd"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_registry_entries()
	_test_aliases()
	_test_report_classification()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("HARNESS REGISTRY SELFTEST: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL %s" % what)


func _test_registry_entries() -> void:
	var src := FileAccess.get_file_as_string(HARNESS_PATH)
	_ok(not src.is_empty(), "harness source readable")
	var missing_fn: Array[String] = []
	var bad_world: Array[String] = []
	var bad_timeout: Array[String] = []
	for mode in HarnessRegistry.modes():
		var e := HarnessRegistry.entry(mode)
		var fn := str(e.get("fn", ""))
		if fn.is_empty() or src.find("func %s(" % fn) < 0:
			missing_fn.append(mode)
		if not HarnessRegistry.WORLD_ALIASES.has(str(e.get("world", ""))):
			bad_world.append(mode)
		if float(e.get("timeout_s", 0.0)) <= 0.0:
			bad_timeout.append(mode)
	_ok(missing_fn.is_empty(), "every mode's fn exists in the harness: missing %s" % str(missing_fn))
	_ok(bad_world.is_empty(), "every mode defaults to mtvernon/walton: %s" % str(bad_world))
	_ok(bad_timeout.is_empty(), "every mode has a watchdog budget: %s" % str(bad_timeout))
	_ok(HarnessRegistry.modes().size() >= 45, "registry carries every capture (%d)" % HarnessRegistry.modes().size())
	for must in ["look", "script", "graph", "siphon", "festivalmode", "worlds", "site-review"]:
		_ok(HarnessRegistry.has_mode(must), "mode %s registered" % must)
	_ok(not HarnessRegistry.has_mode("nonsense"), "unknown mode is not registered")
	_ok(HarnessRegistry.is_builtin_scene("res://scenes/maps/soak_festival_2026.tscn"), "SOAK is a built-in scene")
	_ok(HarnessRegistry.is_builtin_scene("res://scenes/maps/mars_aerial.tscn"), "Mars is a built-in scene")
	_ok(not HarnessRegistry.is_builtin_scene(MapDefinition.GENERATED_SCENE), "the generated shell is NOT built-in")
	_ok(is_equal_approx(HarnessRegistry.timeout_for(PackedStringArray(["look", "graph"])),
		float(HarnessRegistry.entry("look")["timeout_s"]) + float(HarnessRegistry.entry("graph")["timeout_s"])),
		"a chain's budget is the sum of its modes")
	_ok(HarnessRegistry.timeout_for(PackedStringArray()) == HarnessRegistry.DEFAULT_TIMEOUT_S, "empty chain → default budget")
	# The dispatcher's no-op: no capture may still call get_tree().quit() itself.
	var direct_quits := 0
	for line in src.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("#"):
			continue
		if t.find("get_tree().quit(") >= 0:
			direct_quits += 1
	_ok(direct_quits <= 2, "only _finish / the legacy _maybe_quit quit the tree (%d sites)" % direct_quits)


func _rec(id: String, label: String, played: float, scratch := false) -> Dictionary:
	return {"id": id, "name": "", "last_played_unix": played, "scratch": scratch,
		"map": {"label": label, "scene_path": MapDefinition.GENERATED_SCENE, "lat": 1.0, "lon": 2.0}}


func _test_aliases() -> void:
	var recs := [
		_rec("w_old", "23253, State Route 534, McMurray, Mount Vernon, Skagit County", 100.0),
		_rec("w_new", "Something, Mount Vernon, WA", 200.0),
		_rec("w_scr", "copy of Mount Vernon", 999.0, true),
		_rec("w_wal", "18707, Pataha Creek Road, Lane County, Oregon", 50.0),
	]
	_ok(str(HarnessRegistry.pick_world("mtvernon", recs).get("id", "")) == "w_new", "mtvernon → newest matching world")
	_ok(str(HarnessRegistry.pick_world("mt_vernon", recs).get("id", "")) == "w_new", "synonym mt_vernon")
	_ok(str(HarnessRegistry.pick_world("walton", recs).get("id", "")) == "w_wal", "walton → Pataha Creek")
	_ok(str(HarnessRegistry.pick_world("pataha", recs).get("id", "")) == "w_wal", "synonym pataha")
	_ok(str(HarnessRegistry.pick_world("w_old", recs).get("id", "")) == "w_old", "exact id wins")
	_ok(HarnessRegistry.pick_world("atlantis", recs).is_empty(), "unknown alias → nothing")
	_ok(HarnessRegistry.pick_world("", recs).is_empty(), "empty alias → nothing")
	_ok(HarnessRegistry.canonical_alias("Mount-Vernon.tres") == "mtvernon", "canonical alias strips .tres + case")
	var only_scratch := [_rec("s1", "Mount Vernon", 5.0, true)]
	_ok(HarnessRegistry.pick_world("mtvernon", only_scratch).is_empty(), "a scratch world is never picked")


func _test_report_classification() -> void:
	var r := HarnessReport.new()
	r._classify("siphon verify: primed PASS")
	r._classify("poi PASS — 0 failure(s)")
	r._classify("worlds: round trip PASS — all 9 keys")
	r._classify("water: OVERALL FAIL")
	r._classify("building idx=3 -> x.png (FAILED)")
	r._classify("worlds: 2 FAILURE(S)")
	r._classify("fallback failed quietly, retrying")  # lower-case: not a verdict
	r._classify("HARNESS RESULT x FAIL passes=0")       # our own line is ignored
	r._classify("[FAIL] Run 118 m vs 107 m on hand")     # product text, not a verdict
	_ok(r.passes == 3, "three PASS lines counted (%d)" % r.passes)
	_ok(r.fails.size() == 3, "FAIL / FAILED / FAILURE(S) counted, lower-case ignored (%d)" % r.fails.size())
	_ok(r.failed(), "a failure fails the run")
	var s := r.summary("x", 1.25)
	_ok(str(s["status"]) == "FAIL", "summary status FAIL")
	var clean := HarnessReport.new()
	clean._classify("all good PASS")
	_ok(str(clean.summary("y", 2.0)["status"]) == "PASS", "clean report → PASS")
	clean.script_errors.append("res://x.gd:1 — boom")
	_ok(clean.failed(), "a script error alone fails the run")
	var line := HarnessReport.result_line({"mode": "graph", "status": "TIMEOUT", "passes": 4,
		"failures": [], "skipped": [], "script_errors": [], "engine_errors": [], "secs": 12.0, "phase": "graph"})
	_ok(line.begins_with("HARNESS RESULT graph TIMEOUT") and line.find("phase=graph") > 0, "result line format")
